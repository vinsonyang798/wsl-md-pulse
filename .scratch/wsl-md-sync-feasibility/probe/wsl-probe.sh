#!/usr/bin/env bash
# wsl-md-pulse 真机实测（WSL 侧）
#
# 只用发行版自带的 bash + python3 标准库，不安装任何软件。
# 所有输出同时写入 ~/wsl-md-probe/results/ 下的日志文件，跑完把整个 results 目录发回即可。
#
# 推荐顺序：
#   1. bash wsl-probe.sh files [--root ~/notes]   文件变更检测、写入方式、codex 写文件方式
#   2. bash wsl-probe.sh browser                  从 WSL 打开 Windows 浏览器的各种方式
#   3. bash wsl-probe.sh vantage                  Vantage 刷新延迟与阅读位置（会下载一个二进制到 ~/wsl-md-probe/bin，不安装）
#   4. bash wsl-probe.sh serve                    启动探测服务并保持运行，然后去 Windows 运行 windows-probe.ps1
#   （windows-probe.ps1 的最后一步会让你运行 bash wsl-probe.sh serve-bg，并关闭所有 WSL 终端）
#
# 其他：bash wsl-probe.sh serve-bg-stop   停止 serve-bg 启动的后台服务

set -uo pipefail

BASE="${WSL_MD_PROBE_DIR:-$HOME/wsl-md-probe}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUB="${1:-help}"
[ $# -gt 0 ] && shift

usage() {
  sed -n '2,16p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

case "$SUB" in
  files|browser|serve|serve-bg|serve-bg-stop|vantage|bg-child) ;;
  help|-h|--help) usage; exit 0 ;;
  *) usage; exit 2 ;;
esac

if ! command -v python3 >/dev/null 2>&1; then
  echo "需要 python3（Ubuntu 的 WSL 镜像默认自带）。当前发行版没有 python3，请把发行版名称告诉我。"
  exit 1
fi

mkdir -p "$BASE/results" "$BASE/work" "$BASE/bin"
PY="$BASE/probe.py"

cat > "$PY" <<'PYEOF'
import argparse, base64, ctypes, ctypes.util, datetime, hashlib, json, os, platform, random, select
import shutil, signal, socket, statistics, struct, subprocess, sys, tarfile, threading, time, urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

HOME = os.path.expanduser('~')


def now():
    return datetime.datetime.now().strftime('%H:%M:%S.%f')[:-3]


def say(*a):
    print(f'[{now()}]', *a, flush=True)


def section(t):
    print(f'\n===== {t} =====', flush=True)


def sh(cmd, cwd=None):
    print(f'$ {cmd}', flush=True)
    r = subprocess.run(cmd, shell=True, capture_output=True, text=True, cwd=cwd)
    out = (r.stdout + r.stderr).rstrip()
    if out:
        print(out, flush=True)
    return r


def ask(q, default=''):
    try:
        a = input(f'>>> {q} ').strip()
    except EOFError:
        a = ''
    print(f'[answer] {a or default}', flush=True)
    return a or default


def reset_dir(p):
    shutil.rmtree(p, ignore_errors=True)
    os.makedirs(p, exist_ok=True)
    return p


# ---------------------------------------------------------------- inotify（ctypes，无需 inotify-tools）

IN_MODIFY, IN_ATTRIB, IN_CLOSE_WRITE = 0x2, 0x4, 0x8
IN_MOVED_FROM, IN_MOVED_TO, IN_CREATE, IN_DELETE = 0x40, 0x80, 0x100, 0x200
IN_DELETE_SELF, IN_MOVE_SELF, IN_Q_OVERFLOW, IN_IGNORED, IN_ISDIR = 0x400, 0x800, 0x4000, 0x8000, 0x40000000
MASK_NAMES = {IN_MODIFY: 'MODIFY', IN_ATTRIB: 'ATTRIB', IN_CLOSE_WRITE: 'CLOSE_WRITE', IN_MOVED_FROM: 'MOVED_FROM',
              IN_MOVED_TO: 'MOVED_TO', IN_CREATE: 'CREATE', IN_DELETE: 'DELETE', IN_DELETE_SELF: 'DELETE_SELF',
              IN_MOVE_SELF: 'MOVE_SELF', IN_Q_OVERFLOW: 'Q_OVERFLOW', IN_IGNORED: 'IGNORED', IN_ISDIR: 'ISDIR'}
WATCH_MASK = (IN_MODIFY | IN_ATTRIB | IN_CLOSE_WRITE | IN_MOVED_FROM | IN_MOVED_TO | IN_CREATE | IN_DELETE
              | IN_DELETE_SELF | IN_MOVE_SELF)


def mask_names(m):
    return '|'.join(v for k, v in MASK_NAMES.items() if m & k)


class Inotify:
    def __init__(self):
        self.libc = ctypes.CDLL(ctypes.util.find_library('c') or 'libc.so.6', use_errno=True)
        self.libc.inotify_add_watch.argtypes = [ctypes.c_int, ctypes.c_char_p, ctypes.c_uint32]
        self.fd = self.libc.inotify_init1(os.O_NONBLOCK | os.O_CLOEXEC)
        if self.fd < 0:
            e = ctypes.get_errno()
            raise OSError(e, os.strerror(e), 'inotify_init1')
        self.wds = {}

    def add(self, path):
        wd = self.libc.inotify_add_watch(self.fd, os.fsencode(path), WATCH_MASK)
        if wd < 0:
            e = ctypes.get_errno()
            raise OSError(e, os.strerror(e), path)
        self.wds[wd] = path

    def read(self, timeout):
        r, _, _ = select.select([self.fd], [], [], timeout)
        if not r:
            return []
        try:
            buf = os.read(self.fd, 1 << 16)
        except BlockingIOError:
            return []
        t, out, i = time.monotonic(), [], 0
        while i + 16 <= len(buf):
            wd, mask, cookie, ln = struct.unpack_from('iIII', buf, i)
            name = buf[i + 16:i + 16 + ln].rstrip(b'\0').decode(errors='replace')
            i += 16 + ln
            out.append((t, wd, mask, cookie, name))
        return out

    def close(self):
        os.close(self.fd)


class Recorder:
    """在后台线程记录目录下的 inotify 事件；recursive=True 时对新建子目录自动补加监听。"""

    def __init__(self, root, recursive=True, skip=('.git',)):
        self.ino, self.events, self.errors = Inotify(), [], []
        self.recursive, self.skip, self.lock = recursive, skip, threading.Lock()
        if recursive:
            for d, subs, _ in os.walk(root):
                subs[:] = [s for s in subs if s not in skip]
                self._add(d)
        else:
            self._add(root)
        self._stop = threading.Event()
        self.t = threading.Thread(target=self._run, daemon=True)
        self.t.start()

    def _add(self, d):
        try:
            self.ino.add(d)
        except OSError as e:
            self.errors.append(f'{d}: {e}')

    def _run(self):
        while not self._stop.is_set():
            for t, wd, mask, cookie, name in self.ino.read(0.05):
                base = self.ino.wds.get(wd, '?')
                p = os.path.join(base, name) if name else base
                size = ino = None
                try:
                    st = os.stat(p)
                    size, ino = st.st_size, st.st_ino
                except OSError:
                    pass
                if self.recursive and mask & IN_CREATE and mask & IN_ISDIR and os.path.basename(p) not in self.skip:
                    self._add(p)
                with self.lock:
                    self.events.append(dict(t=t, mask=mask, ev=mask_names(mask), path=p, size=size, ino=ino))

    def mark(self):
        with self.lock:
            return len(self.events)

    def since(self, i=0):
        with self.lock:
            return list(self.events[i:])

    def settle(self, quiet=0.4, maxwait=6.0):
        end, n, last = time.monotonic() + maxwait, -1, time.monotonic()
        while time.monotonic() < end:
            m = self.mark()
            if m != n:
                n, last = m, time.monotonic()
            elif time.monotonic() - last >= quiet:
                return
            time.sleep(0.05)

    def close(self):
        self._stop.set()
        self.t.join()
        self.ino.close()


def print_events(evs, t0, root, skip_git=True):
    for e in evs:
        rel = os.path.relpath(e['path'], root)
        if skip_git and (rel == '.git' or rel.startswith('.git/')):
            continue
        print(f"    +{(e['t'] - t0) * 1000:8.1f}ms  {e['ev']:<22} {rel:<28} size={e['size']} inode={e['ino']}", flush=True)


# ---------------------------------------------------------------- files

LONG_DOC = ''.join(f'## 第 {i} 节\n\n' + ''.join(f'第 {i} 节的第 {j} 行文字。\n' for j in range(1, 7)) + '\n'
                   for i in range(1, 41))


def w_inplace(p, text):
    with open(p, 'w') as f:
        f.write(text)


def w_chunked(p, text):
    step = max(1, len(text) // 3)
    with open(p, 'w') as f:
        for i in range(0, len(text), step):
            f.write(text[i:i + step])
            f.flush()
            time.sleep(0.05)


def w_tmp_rename(p, text):
    tmp = p + '.tmp'
    with open(tmp, 'w') as f:
        f.write(text)
    os.replace(tmp, p)


def w_truncate_then_write(p, text):
    open(p, 'w').close()
    time.sleep(0.2)
    with open(p, 'w') as f:
        f.write(text)


WRITERS = [('原地覆盖写', w_inplace), ('分三块写', w_chunked), ('写临时文件再改名', w_tmp_rename),
           ('先清空、0.2 秒后再写', w_truncate_then_write)]


def analyse_target(evs, target):
    mine = [e for e in evs if e['path'] == target]
    zero = any(e['size'] == 0 for e in mine if e['mask'] & (IN_MODIFY | IN_CLOSE_WRITE | IN_CREATE | IN_MOVED_TO))
    renamed = any(e['mask'] & IN_MOVED_TO for e in mine)
    return zero, renamed


def cmd_files(a):
    section('0 环境信息')
    for c in ['date -Is', 'uname -r', 'head -2 /etc/os-release', 'echo "WSL_DISTRO_NAME=${WSL_DISTRO_NAME:-}"',
              'wslinfo --version 2>&1 || true', 'wslinfo --networking-mode 2>&1 || true',
              'stat -f -c "HOME 所在文件系统: %T" ~', 'findmnt -no FSTYPE,SOURCE -T ~ 2>/dev/null || true',
              'free -h | head -2', 'nproc', 'python3 --version',
              'for c in codex vim git curl inotifywait; do printf "%-12s %s\\n" $c "$(command -v $c || echo 无)"; done',
              'codex --version 2>/dev/null || true']:
        sh(c)

    section('F1 inotify 上限（文件检测研究 E1）')
    sh('for f in max_user_watches max_user_instances max_queued_events; do echo "$f=$(cat /proc/sys/fs/inotify/$f)"; done')
    sh("grep -rs inotify /etc/sysctl.conf /etc/sysctl.d /usr/lib/sysctl.d || echo '(没有 sysctl 覆盖 inotify)'")
    root = os.path.expanduser(a.root)
    if os.path.isdir(root):
        dirs = files = 0
        for d, subs, fs in os.walk(root):
            subs[:] = [s for s in subs if not s.startswith('.') and s != 'node_modules']
            dirs += 1
            files += sum(1 for f in fs if f.endswith(('.md', '.markdown')))
        limit = int(open('/proc/sys/fs/inotify/max_user_watches').read())
        say(f'笔记根目录 {root}: 目录 {dirs} 个, md 文件 {files} 个; 每个目录一个监听 → 占 max_user_watches 的 {dirs / limit:.2%}')
    else:
        say(f'笔记根目录 {root} 不存在，跳过规模统计（可用 --root 指定）')

    work = reset_dir(os.path.join(a.base, 'work', 'files'))

    section('F2 不同写入方式产生的事件序列（文件检测研究 E7 的扩展）')
    for label, fn in WRITERS:
        d = reset_dir(os.path.join(work, 'pattern'))
        target = os.path.join(d, 'a.md')
        w_inplace(target, LONG_DOC)
        ino_before = os.stat(target).st_ino
        rec = Recorder(d, recursive=False)
        t0 = time.monotonic()
        fn(target, LONG_DOC.replace('第 3 节的第 1 行', '第 3 节的第 1 行（已修改）'))
        rec.settle()
        rec.close()
        evs = rec.since()
        zero, renamed = analyse_target(evs, target)
        say(f'[{label}] 事件 {len(evs)} 个; inode {"改变" if os.stat(target).st_ino != ino_before else "不变"}; '
            f'中途出现 0 字节: {"是" if zero else "否"}; 通过改名落地: {"是" if renamed else "否"}')
        print_events(evs, t0, d)

    section('F3 模拟 agent 连续快速修改多个文件')
    d = reset_dir(os.path.join(work, 'burst'))
    names = [f'doc{i}.md' for i in range(5)]
    for n in names:
        w_inplace(os.path.join(d, n), LONG_DOC)
    rec = Recorder(d, recursive=False)
    last_write_end = {}
    t0 = time.monotonic()
    for r in range(20):
        for n in names:
            fn = random.choice([w_inplace, w_tmp_rename])
            fn(os.path.join(d, n), LONG_DOC + f'\n第 {r} 轮\n')
            last_write_end[n] = time.monotonic()
            time.sleep(0.01)
    rec.settle(quiet=0.5)
    rec.close()
    evs = rec.since()
    overflow = any(e['mask'] & IN_Q_OVERFLOW for e in evs)
    worst, missing = 0.0, []
    for n in names:
        p = os.path.join(d, n)
        after = [e['t'] for e in evs if e['path'] == p and e['t'] >= last_write_end[n] - 0.005
                 and e['mask'] & (IN_CLOSE_WRITE | IN_MOVED_TO)]
        if not after:
            missing.append(n)
        else:
            worst = max(worst, max(after) - last_write_end[n])
    all_end = max(last_write_end.values())
    last_ev = max((e['t'] for e in evs), default=all_end)
    content_ok = all(open(os.path.join(d, n)).read().endswith('第 19 轮\n') for n in names)
    say(f'5 个文件 × 20 轮，共写 100 次，耗时 {(all_end - t0) * 1000:.0f}ms; 收到事件 {len(evs)} 个; Q_OVERFLOW: {"有" if overflow else "无"}')
    say(f'最后一次写入落地事件缺失的文件: {missing or "无"}; 最后写入到其事件的最大延迟 {worst * 1000:.1f}ms')
    say(f'按 150ms 防抖估算：最后一次写入后 {(last_ev + 0.15 - all_end) * 1000:.0f}ms 触发刷新; 最终内容正确: {"是" if content_ok else "否"}')

    section('F4 新建子目录后立刻写文件（递归监听的竞态）')
    d = reset_dir(os.path.join(work, 'tree'))
    rec = Recorder(d, recursive=True)
    misses = 0
    for i in range(20):
        sub = os.path.join(d, f'new{i}', 'deep')
        os.makedirs(sub)
        w_inplace(os.path.join(sub, 'x.md'), 'hello\n')
    rec.settle()
    rec.close()
    evs = rec.since()
    for i in range(20):
        p = os.path.join(d, f'new{i}', 'deep', 'x.md')
        if not any(e['path'] == p for e in evs):
            misses += 1
    say(f'20 次"建目录后立刻写文件"中，文件事件丢失 {misses} 次（>0 说明实现必须在补加监听后重新扫描新目录）')

    section('F5 vim 保存（对照，文件检测研究 E7）')
    if shutil.which('vim'):
        d = reset_dir(os.path.join(work, 'vim'))
        target = os.path.join(d, 'v.md')
        variants = [('backupcopy=no', ['-u', 'NONE', '-N', '-c', 'set backupcopy=no']),
                    ('backupcopy=yes', ['-u', 'NONE', '-N', '-c', 'set backupcopy=yes'])]
        vimrc = os.path.join(HOME, '.vimrc')
        if os.path.exists(vimrc):
            variants.append(('你的 ~/.vimrc', ['-u', vimrc]))
        for label, opts in variants:
            w_inplace(target, LONG_DOC)
            ino_before = os.stat(target).st_ino
            rec = Recorder(d, recursive=False)
            t0 = time.monotonic()
            subprocess.run(['vim', '-Es'] + opts + ['-c', 'call append(line("$"), "vim 追加")', '-c', 'wq', target],
                           capture_output=True, timeout=30)
            rec.settle()
            rec.close()
            evs = rec.since()
            say(f'[vim {label}] inode {"改变" if os.stat(target).st_ino != ino_before else "不变"}')
            print_events(evs, t0, d)
    else:
        say('没有 vim，跳过')

    section('F6 codex cli 写文件的方式（最关键）')
    codex_probe(a, work)
    say(f'files 完成。日志在 {a.base}/results/')


CODEX_PROMPTS = [
    ('改一篇（上方插入 + 整段重写）',
     '只修改当前目录下的 a.md：在“## 第 2 节”这一节的末尾后面插入一个新的小节“## 新增小节”，写 3 行内容；'
     '再把“## 第 30 节”这一节的正文整段改写成 5 行新内容。不要修改其他文件，不要运行测试。'),
    ('连续改多篇', '在当前目录下：新建 b.md，写一个标题和 10 行内容；把 c.md 的每一节末尾各追加一行“已审阅”；'
               '最后在 a.md 末尾追加一个“## 总结”小节。不要运行测试。'),
]


def fresh_codex_dir(work):
    d = reset_dir(os.path.join(work, 'codex'))
    w_inplace(os.path.join(d, 'a.md'), LONG_DOC)
    w_inplace(os.path.join(d, 'c.md'), LONG_DOC[:2000])
    if shutil.which('git'):
        subprocess.run('git init -q && git add -A && git -c user.email=p@p -c user.name=probe commit -qm init',
                       shell=True, cwd=d, capture_output=True)
    return d


def codex_probe(a, work):
    has_codex = shutil.which('codex') is not None
    say(f'codex {"已找到" if has_codex else "不在 PATH 中"}；每个场景都在全新的测试目录里进行')
    for label, prompt in CODEX_PROMPTS:
        d = fresh_codex_dir(work)
        print(f'\n--- codex 场景：{label}（目录 {d}）---', flush=True)
        print(f'提示词：{prompt}', flush=True)
        choice = ask('选择：a = 脚本自动运行 codex exec；m = 我自己在另一个终端里让 codex 做；s = 跳过 [a/m/s]',
                     'a' if has_codex else 'm')
        if choice == 's':
            continue
        inodes = {n: os.stat(os.path.join(d, n)).st_ino for n in os.listdir(d) if n.endswith('.md')}
        rec = Recorder(d, recursive=True)
        t0 = time.monotonic()
        if choice == 'a':
            argv = ['codex', 'exec', '--full-auto', '--skip-git-repo-check', '-C', d, prompt]
            say('运行:', ' '.join(argv[:6]), '"<提示词>"')
            try:
                r = subprocess.run(argv, capture_output=True, text=True, timeout=900)
                tail = (r.stdout + r.stderr).strip().splitlines()[-15:]
                say(f'codex exec 退出码 {r.returncode}; 输出末尾:')
                print('\n'.join('    ' + x for x in tail), flush=True)
                if r.returncode != 0:
                    ask(f'自动运行失败。请在另一个终端 cd {d} 后手动让 codex 执行上面的提示词，完成后按回车')
            except (subprocess.TimeoutExpired, OSError) as e:
                say('codex exec 运行出错:', e)
                ask(f'请在另一个终端 cd {d} 后手动让 codex 执行上面的提示词，完成后按回车')
        else:
            ask(f'请在另一个终端 cd {d}，启动 codex，把上面的提示词发给它；codex 改完后回到这里按回车')
        rec.settle(quiet=1.0)
        rec.close()
        evs = rec.since()
        say(f'记录到事件 {len(evs)} 个（已隐藏 .git 内部事件）:')
        print_events(evs, t0, d)
        for n in sorted(os.listdir(d)):
            p = os.path.join(d, n)
            if not n.endswith('.md'):
                continue
            zero, renamed = analyse_target(evs, p)
            ino_now = os.stat(p).st_ino
            changed = '新建' if n not in inodes else ('改变' if ino_now != inodes[n] else '不变')
            touched = any(e['path'] == p for e in evs)
            if touched:
                say(f'  {n}: inode {changed}; 中途出现 0 字节: {"是" if zero else "否"}; 通过改名落地: {"是" if renamed else "否"}')
        others = sorted({os.path.relpath(e['path'], d) for e in evs
                         if not e['path'].endswith('.md') and '/.git' not in e['path'] and e['path'] != d})
        if others:
            say('  出现过的非 md 路径（临时文件等）:', others[:20])


# ---------------------------------------------------------------- browser

def win_exe(rel):
    for root in ('/mnt/c', '/c'):
        p = os.path.join(root, rel)
        if os.path.exists(p):
            return p
    return shutil.which(os.path.basename(rel)) or os.path.join('/mnt/c', rel)


def cmd_browser(a):
    section('B0 环境（访问通道研究 E6/E7）')
    sh('for c in wslview xdg-open cmd.exe powershell.exe explorer.exe; do printf "%-15s %s\\n" $c "$(command -v $c || echo 不在 PATH)"; done')
    sh('cat /etc/wsl.conf 2>/dev/null || echo "(没有 /etc/wsl.conf)"')
    sh('head -3 /proc/sys/fs/binfmt_misc/WSLInterop 2>&1 || echo "(没有 WSLInterop 注册)"')
    url = 'http://127.0.0.1:8820/?path=docs%2Fa%20b.md&x=1'
    say('测试 URL:', url)
    say('浏览器里页面打不开没关系，只需要看：浏览器有没有被打开、地址栏里的 URL 是否完整（结尾是 &x=1）。')
    cmd, ps = win_exe('Windows/System32/cmd.exe'), win_exe('Windows/System32/WindowsPowerShell/v1.0/powershell.exe')
    methods = [('cmd.exe /c start', [cmd, '/c', 'start', '', url]),
               ('cmd.exe /c start（& 转义为 ^&）', [cmd, '/c', 'start', '', url.replace('&', '^&')]),
               ('powershell.exe Start-Process', [ps, '-NoProfile', '-NonInteractive', '-Command', f"Start-Process '{url}'"]),
               ('explorer.exe', [win_exe('Windows/explorer.exe'), url])]
    for tool in ('wslview', 'xdg-open'):
        if shutil.which(tool):
            methods.append((tool, [tool, url]))
    for label, argv in methods:
        if ask(f'按回车测试【{label}】（输入 s 跳过）') == 's':
            continue
        t = time.monotonic()
        try:
            r = subprocess.run(argv, cwd=HOME, capture_output=True, text=True, timeout=30)
            say(f'{label}: 退出码 {r.returncode}, 耗时 {(time.monotonic() - t) * 1000:.0f}ms, 输出: {(r.stdout + r.stderr).strip()[:300]}')
        except (OSError, subprocess.TimeoutExpired) as e:
            say(f'{label}: 启动失败 {e}')
        ask('浏览器打开了吗？地址栏的 URL 是否完整（含 &x=1）？输入 y / n / 其他说明:')


# ---------------------------------------------------------------- serve（给 windows-probe.ps1 用）

PAGE = '''<!doctype html><meta charset=utf-8><title>wsl-md-probe</title>
<style>body{font:14px ui-monospace,Consolas,monospace;margin:1.5em}#st{font-size:18px;margin:.5em 0}</style>
<h3>wsl-md-probe：请保持此页打开，直到 PowerShell 脚本结束</h3><div id=st></div><pre id=log></pre>
<script>
const L=document.getElementById('log'),S=document.getElementById('st');let lastWs=0,lastSse=0,tick=Date.now(),wsDelay=1000;
function log(m){const l=new Date().toLocaleTimeString()+' '+m;L.textContent=l+'\\n'+L.textContent;fetch('/log',{method:'POST',body:l}).catch(()=>{});}
function sse(){const es=new EventSource('/sse');es.onopen=()=>log('sse open');es.onmessage=()=>{lastSse=Date.now()};es.onerror=()=>log('sse error（浏览器会自动重连）');}
function ws(){const w=new WebSocket('ws://'+location.host+'/ws');w.onopen=()=>{wsDelay=1000;log('ws open')};w.onmessage=()=>{lastWs=Date.now()};
 w.onclose=e=>{log('ws close code='+e.code+'，'+wsDelay/1000+'s 后重连');setTimeout(ws,wsDelay);wsDelay=Math.min(wsDelay*2,30000)};}
setInterval(()=>{const n=Date.now();if(n-tick>5000)log('检测到时间跳变 '+((n-tick)/1000).toFixed(0)+'s（可能刚睡眠/唤醒）');tick=n;
 S.textContent='距上次 ws 消息 '+((n-lastWs)/1000).toFixed(1)+'s；距上次 sse 消息 '+((n-lastSse)/1000).toFixed(1)+'s';},500);
document.addEventListener('visibilitychange',()=>log('visibility='+document.visibilityState));
log('page loaded '+location.href);sse();ws();
</script>'''.encode()

WS_GUID = '258EAFA5-E914-47DA-95CA-C5AB0DC85B11'


class ProbeHandler(BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'

    def log_message(self, *a):
        pass

    def _send(self, code, body, ctype='text/plain; charset=utf-8'):
        self.send_response(code)
        self.send_header('Content-Type', ctype)
        self.send_header('Content-Length', str(len(body)))
        self.send_header('Cache-Control', 'no-store')
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        port = self.server.server_address[1]
        if self.path == '/sse':
            return self._sse()
        if self.path == '/ws':
            return self._ws()
        if port == 8820 and self.path.split('?')[0] == '/':
            say(f'[{port}] page GET from {self.client_address[0]}')
            return self._send(200, PAGE, 'text/html; charset=utf-8')
        say(f'[{port}] GET {self.path} from {self.client_address[0]} Host={self.headers.get("Host")}')
        self._send(200, f'ok {port}\n'.encode())

    def do_POST(self):
        n = int(self.headers.get('Content-Length') or 0)
        body = self.rfile.read(n).decode(errors='replace')
        if self.path == '/log':
            say('[浏览器页面]', body)
        self._send(204, b'')

    def _sse(self):
        self.send_response(200)
        self.send_header('Content-Type', 'text/event-stream')
        self.send_header('Cache-Control', 'no-store')
        self.send_header('Connection', 'close')
        self.end_headers()
        say('sse connect', self.client_address)
        n = 0
        try:
            while True:
                self.wfile.write(f'data: {n}\n\n'.encode())
                self.wfile.flush()
                n += 1
                time.sleep(1)
        except OSError as e:
            say('sse gone', self.client_address, e)
        self.close_connection = True

    def _ws(self):
        key = self.headers.get('Sec-WebSocket-Key')
        if not key:
            return self._send(400, b'need websocket\n')
        acc = base64.b64encode(hashlib.sha1((key + WS_GUID).encode()).digest()).decode()
        self.send_response(101, 'Switching Protocols')
        self.send_header('Upgrade', 'websocket')
        self.send_header('Connection', 'Upgrade')
        self.send_header('Sec-WebSocket-Accept', acc)
        self.end_headers()
        self.wfile.flush()
        say('ws connect', self.client_address, 'Origin=', self.headers.get('Origin'))
        n = 0
        try:
            while True:
                payload = str(n).encode()
                self.connection.sendall(bytes([0x81, len(payload)]) + payload)
                n += 1
                time.sleep(1)
        except OSError as e:
            say('ws gone', self.client_address, e)
        self.close_connection = True


class V6Server(ThreadingHTTPServer):
    address_family = socket.AF_INET6
    v6only = 0

    def server_bind(self):
        self.socket.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, self.v6only)
        super().server_bind()


class V6OnlyServer(V6Server):
    v6only = 1


def start_server(cls, addr, label):
    try:
        srv = cls(addr, ProbeHandler)
    except OSError as e:
        say(f'  {label}: 启动失败 {e}')
        return None
    srv.daemon_threads = True
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    say(f'  {label}: 监听 {addr[0]}:{addr[1]}')
    return srv


def copy_ps1_to_windows(a):
    src = os.path.join(a.script_dir, 'windows-probe.ps1')
    if not os.path.exists(src):
        say('找不到 windows-probe.ps1（应和 wsl-probe.sh 放在同一目录）')
        return
    try:
        r = subprocess.run([win_exe('Windows/System32/cmd.exe'), '/c', 'echo %USERPROFILE%'], cwd='/mnt/c' if os.path.isdir('/mnt/c') else HOME,
                           capture_output=True, text=True, timeout=20)
        winprof = r.stdout.strip()
        linux = subprocess.run(['wslpath', '-u', winprof], capture_output=True, text=True).stdout.strip()
        dst_dir = os.path.join(linux, 'wsl-md-probe')
        os.makedirs(dst_dir, exist_ok=True)
        shutil.copy(src, os.path.join(dst_dir, 'windows-probe.ps1'))
        say('已把 Windows 脚本复制到', winprof + r'\wsl-md-probe\windows-probe.ps1')
        print('\n在 Windows 的 PowerShell 里运行（复制整行）:\n'
              f'  powershell -ExecutionPolicy Bypass -File "{winprof}\\wsl-md-probe\\windows-probe.ps1"\n', flush=True)
    except (OSError, subprocess.TimeoutExpired) as e:
        say('自动复制到 Windows 失败（interop 可能被禁用）:', e)
        say(f'请手动把 {src} 复制到 Windows 上再运行。')


def cmd_serve(a):
    section('S 启动探测服务（访问通道研究 E1/E3）')
    sh('wslinfo --networking-mode 2>&1 || true')
    servers = [start_server(ThreadingHTTPServer, ('127.0.0.1', 8801), '8801 绑 127.0.0.1'),
               start_server(ThreadingHTTPServer, ('0.0.0.0', 8802), '8802 绑 0.0.0.0'),
               start_server(V6Server, ('::', 8803), '8803 绑 :: 双栈'),
               start_server(V6OnlyServer, ('::1', 8804), '8804 只绑 ::1'),
               start_server(ThreadingHTTPServer, ('127.0.0.1', 8820), '8820 探测页 + SSE + WebSocket')]
    sh("ss -ltn 2>/dev/null | grep -E ':(880[1-4]|8820)\\b' || true")
    copy_ps1_to_windows(a)
    say('服务运行中。PowerShell 脚本跑完之前不要关闭这个终端（它的最后一步会让你关闭）。Ctrl+C 结束。')
    try:
        while True:
            time.sleep(3600)
    except KeyboardInterrupt:
        pass
    for s in servers:
        if s:
            s.shutdown()


def cmd_serve_bg(a):
    pidf = os.path.join(a.base, 'serve-bg.pid')
    out = os.path.join(a.base, 'results', f'bg-8830-{datetime.datetime.now():%Y%m%d-%H%M%S}.log')
    p = subprocess.Popen([sys.executable, '-u', __file__, 'bg-child', '--base', a.base],
                         stdin=subprocess.DEVNULL, stdout=open(out, 'a'), stderr=subprocess.STDOUT, start_new_session=True)
    open(pidf, 'w').write(str(p.pid))
    say(f'后台服务已启动：127.0.0.1:8830，pid={p.pid}，日志 {out}')
    say('现在关闭所有 WSL 终端窗口（包括 VS Code 的 WSL 窗口），然后回到 PowerShell 按回车。')


def cmd_bg_child(a):
    say('bg-child start pid', os.getpid())
    signal.signal(signal.SIGTERM, lambda *_: (say('bg-child got SIGTERM'), os._exit(0)))
    srv = ThreadingHTTPServer(('127.0.0.1', 8830), ProbeHandler)
    srv.serve_forever()


def cmd_serve_bg_stop(a):
    pidf = os.path.join(a.base, 'serve-bg.pid')
    try:
        pid = int(open(pidf).read())
        os.kill(pid, signal.SIGTERM)
        say('已停止 pid', pid)
    except (OSError, ValueError) as e:
        say('没有在运行的后台服务:', e)


# ---------------------------------------------------------------- vantage

class WSClient:
    def __init__(self, host, port, path):
        self.s = socket.create_connection((host, port), timeout=5)
        key = base64.b64encode(os.urandom(16)).decode()
        self.s.sendall((f'GET {path} HTTP/1.1\r\nHost: {host}:{port}\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n'
                        f'Sec-WebSocket-Key: {key}\r\nSec-WebSocket-Version: 13\r\n\r\n').encode())
        buf = b''
        while b'\r\n\r\n' not in buf:
            c = self.s.recv(4096)
            if not c:
                raise ConnectionError('握手时连接关闭')
            buf += c
        head, self.buf = buf.split(b'\r\n\r\n', 1)
        if b' 101' not in head.split(b'\r\n')[0]:
            raise ConnectionError(head.decode(errors='replace'))
        self.s.settimeout(None)

    def _read(self, n):
        while len(self.buf) < n:
            c = self.s.recv(1 << 16)
            if not c:
                raise ConnectionError('closed')
            self.buf += c
        d, self.buf = self.buf[:n], self.buf[n:]
        return d

    def _send(self, op, data):
        mk, ln = os.urandom(4), len(data)
        hdr = bytes([0x80 | op]) + (bytes([0x80 | ln]) if ln < 126 else bytes([0x80 | 126]) + struct.pack('>H', ln))
        self.s.sendall(hdr + mk + bytes(x ^ mk[i % 4] for i, x in enumerate(data)))

    def recv(self):
        msg = b''
        while True:
            b1, b2 = self._read(2)
            ln = b2 & 0x7f
            if ln == 126:
                ln = struct.unpack('>H', self._read(2))[0]
            elif ln == 127:
                ln = struct.unpack('>Q', self._read(8))[0]
            mk = self._read(4) if b2 & 0x80 else None
            data = self._read(ln)
            if mk:
                data = bytes(x ^ mk[i % 4] for i, x in enumerate(data))
            op = b1 & 0x0f
            if op == 9:
                self._send(0xA, data)
                continue
            if op == 8:
                raise ConnectionError('server close')
            if op == 0xA:
                continue
            msg += data
            if b1 & 0x80:
                return msg.decode(errors='replace')


def fetch_vantage(a):
    arch = {'x86_64': 'amd64', 'amd64': 'amd64', 'aarch64': 'arm64', 'arm64': 'arm64'}.get(platform.machine().lower())
    if not arch:
        raise RuntimeError(f'不支持的架构 {platform.machine()}')
    binp = os.path.join(a.base, 'bin', 'vantage')
    if os.path.exists(binp):
        return binp
    url = f'https://github.com/mschulkind-oss/vantage/releases/download/v0.7.1/vantage_0.7.1_linux_{arch}.tar.gz'
    try:
        with urllib.request.urlopen('https://api.github.com/repos/mschulkind-oss/vantage/releases/latest', timeout=20) as r:
            rel = json.load(r)
        url = next(x['browser_download_url'] for x in rel['assets'] if x['name'].endswith(f'linux_{arch}.tar.gz'))
    except Exception as e:
        say('查询最新版本失败，使用 v0.7.1:', e)
    say('下载', url)
    tgz = os.path.join(a.base, 'bin', 'vantage.tar.gz')
    urllib.request.urlretrieve(url, tgz)
    with tarfile.open(tgz) as t:
        m = next(m for m in t.getmembers() if os.path.basename(m.name) == 'vantage' and m.isfile())
        with t.extractfile(m) as src, open(binp, 'wb') as dst:
            shutil.copyfileobj(src, dst)
    os.chmod(binp, 0o755)
    return binp


def cmd_vantage(a):
    section('V0 准备 Vantage（现成工具差距研究 待验证项 3/6/7）')
    try:
        binp = fetch_vantage(a)
    except Exception as e:
        say('获取 Vantage 失败，跳过:', e)
        return
    sh(f'"{binp}" --version 2>&1 | head -3; file "{binp}" 2>/dev/null || true')
    root = reset_dir(os.path.join(a.base, 'work', 'vantage-root'))
    mermaid = '## 图\n\n```mermaid\ngraph TD\n  A[agent 写文件] --> B[inotify]\n  B --> C[浏览器刷新]\n```\n\n'
    doc = LONG_DOC.replace('## 第 5 节\n', mermaid + '## 第 5 节\n')
    for n in ('long.md', 'a.md', 'b.md'):
        w_inplace(os.path.join(root, n), doc)
    port = 8840
    out = os.path.join(a.base, 'results', f'vantage-server-{datetime.datetime.now():%Y%m%d-%H%M%S}.log')
    proc = subprocess.Popen([binp, root, '--no-open', '--port', str(port)], stdout=open(out, 'a'), stderr=subprocess.STDOUT)
    say(f'Vantage pid={proc.pid}，服务日志 {out}')
    try:
        for _ in range(60):
            try:
                urllib.request.urlopen(f'http://127.0.0.1:{port}/', timeout=1).read(10)
                break
            except Exception:
                time.sleep(0.25)
        else:
            say('Vantage 15 秒内没有就绪，查看上面的服务日志')
            return
        vantage_latency(port, root)
        vantage_visual(port, root, doc)
    finally:
        ask('按回车停止 Vantage')
        proc.terminate()
        try:
            proc.wait(5)
        except subprocess.TimeoutExpired:
            proc.kill()


def vantage_latency(port, root):
    ws = WSClient('127.0.0.1', port, '/api/ws')
    msgs, lock = [], threading.Lock()

    def reader():
        try:
            while True:
                m = ws.recv()
                with lock:
                    msgs.append((time.monotonic(), m))
        except (ConnectionError, OSError):
            pass

    threading.Thread(target=reader, daemon=True).start()
    time.sleep(1)
    with lock:
        say('WebSocket 首条消息:', msgs[0][1][:200] if msgs else '(无)')

    def first_notice(name, after, timeout=5.0):
        end = time.monotonic() + timeout
        while True:
            with lock:
                for t, m in msgs:
                    if t >= after and '"files_changed"' in m and name in m:
                        return t
            if time.monotonic() >= end:
                return None
            time.sleep(0.01)

    section('V1 单次写入 → 服务端推送 files_changed 的延迟')
    lat = []
    for i in range(5):
        t = time.monotonic()
        w_inplace(os.path.join(root, 'long.md'), open(os.path.join(root, 'long.md')).read() + f'\n单次写入 {i}\n')
        n = first_notice('long.md', t)
        lat.append(None if n is None else (n - t) * 1000)
        time.sleep(1.5)
    say('5 次延迟(ms):', ['超时' if x is None else f'{x:.0f}' for x in lat])

    for tag, gap in (('V2', 0.15), ('V3', 0.05)):
        section(f'{tag} agent 式连续写入 3 个文件（每 {gap * 1000:.0f}ms 一次，持续 4 秒）')
        writes = []
        names = ['a.md', 'b.md', 'long.md']
        t_end = time.monotonic() + 4
        i = 0
        while time.monotonic() < t_end:
            n = names[i % 3]
            p = os.path.join(root, n)
            w_inplace(p, open(p).read() + f'\n连续写入 {i}\n')
            writes.append((time.monotonic(), n))
            i += 1
            time.sleep(gap)
        time.sleep(3)
        delays = []
        for t, n in writes:
            x = first_notice(n, t, timeout=0)
            delays.append(None if x is None else (x - t) * 1000)
        ok = [d for d in delays if d is not None]
        say(f'写入 {len(writes)} 次；收到对应推送 {len(ok)} 次；未等到推送 {len(delays) - len(ok)} 次')
        if ok:
            say(f'写入→推送延迟 ms：中位数 {statistics.median(ok):.0f}，最大 {max(ok):.0f}')
            say(f'浏览器端还会再合并 150–500ms 并重新取文档，画面更新的估计上限 ≈ {max(ok) + 500:.0f}ms + 取数时间（验收标准 ≤1000ms）')
        say('最后一次写入的推送延迟(ms):', 'N/A' if delays[-1] is None else f'{delays[-1]:.0f}')
        time.sleep(1.5)


def insert_section(doc):
    extra = '## 插入的新节\n\n' + ''.join(f'新插入的第 {j} 行，用来把下面的内容往下推。\n' for j in range(1, 31)) + '\n'
    return doc.replace('## 第 4 节\n', extra + '## 第 4 节\n', 1)


def vantage_visual(port, root, doc):
    section('V4 Windows 浏览器里的阅读位置（需要你看屏幕）')
    url = f'http://127.0.0.1:{port}/'
    try:
        subprocess.run([win_exe('Windows/System32/cmd.exe'), '/c', 'start', '', url], cwd=HOME, capture_output=True, timeout=20)
    except (OSError, subprocess.TimeoutExpired):
        pass
    say(f'如果浏览器没有自动打开，请在 Windows 浏览器中打开 {url}')
    p = os.path.join(root, 'long.md')
    cases = [('上方插入一节（原地写）', lambda: w_inplace(p, insert_section(doc))),
             ('上方插入一节（先清空、0.2 秒后再写）', lambda: w_truncate_then_write(p, insert_section(doc))),
             ('上方插入一节（写临时文件再改名）', lambda: w_tmp_rename(p, insert_section(doc)))]
    for label, act in cases:
        w_inplace(p, doc)
        ask(f'【{label}】在浏览器中点开 long.md，滚动到“第 20 节”标题位于屏幕顶部附近，然后按回车（脚本随即修改文件）')
        act()
        say('已修改 long.md')
        ask('画面现在停在哪？a = 仍在第 20 节；b = 偏到别的节（写出节号）；c = 回到顶部。刷新大约用了多久（秒）？例如 "b 19 0.5"：')
    ask('另外：刷新时有没有白屏闪烁、Mermaid 图（第 5 节上方）是否正常显示？写下观察:')


# ---------------------------------------------------------------- main

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('sub')
    ap.add_argument('--base', required=True)
    ap.add_argument('--script-dir', default='.')
    ap.add_argument('--root', default='~/notes')
    a = ap.parse_args()
    {'files': cmd_files, 'browser': cmd_browser, 'serve': cmd_serve, 'serve-bg': cmd_serve_bg,
     'serve-bg-stop': cmd_serve_bg_stop, 'bg-child': cmd_bg_child, 'vantage': cmd_vantage}[a.sub](a)


if __name__ == '__main__':
    main()
PYEOF

if [ "$SUB" = "bg-child" ]; then
  exec python3 -u "$PY" "$SUB" --base "$BASE" "$@"
fi

LOG="$BASE/results/wsl-$SUB-$(date +%Y%m%d-%H%M%S).log"
echo "# wsl-probe $SUB  $(date -Is)  日志: $LOG" | tee -a "$LOG"
python3 -u "$PY" "$SUB" --base "$BASE" --script-dir "$SCRIPT_DIR" "$@" 2>&1 | tee -a "$LOG"
echo "# 结束。日志: $LOG"
