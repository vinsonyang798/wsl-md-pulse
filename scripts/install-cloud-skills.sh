#!/usr/bin/env bash
# Install project Cloud Agent skills into ~/.cursor/skills.
#
# Cloud Agents read real directories there and skip symbolic links, so every
# copy is a real tree.
#
# Preference order:
# 1. Vendored .cursor/skills in the current checkout (includes kb).
# 2. Skills already present in ~/.cursor/skills (snapshot / previous install).
# 3. Fallback: pinned mattpocock/skills tarball, plus kb from agent-env
#    when GH_TOKEN can read that private repo.
set -euo pipefail

PINNED_SHA="74ca5fe077456a0b3b2f5310cf9430999fd0b5fd"
DEST="${HOME}/.cursor/skills"
WORKDIR="${TMPDIR:-/tmp}/cloud-skills-${PINNED_SHA}"
AGENT_ENV_REPO="${AGENT_ENV_REPO:-https://github.com/vinsonyang798/agent-env.git}"

MATT_SKILLS=(
  skills/engineering/grill-with-docs
  skills/engineering/implement
  skills/engineering/to-spec
  skills/engineering/to-tickets
  skills/engineering/improve-codebase-architecture
  skills/engineering/domain-modeling
  skills/engineering/codebase-design
  skills/engineering/tdd
  skills/engineering/code-review
  skills/engineering/setup-matt-pocock-skills
  skills/productivity/grilling
)

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VENDORED="${HERE}/../.cursor/skills"

mkdir -p "${DEST}"

copy_one() {
  local src="$1" name="$2"
  if [[ ! -f "${src}/SKILL.md" ]]; then
    echo "install-cloud-skills: ${name} has no SKILL.md" >&2
    return 1
  fi
  local dest="${DEST}/${name}"
  rm -rf "${dest}"
  cp -R "${src}" "${dest}"
  if [[ -L "${dest}" ]]; then
    echo "install-cloud-skills: ${name} unpacked as a symlink" >&2
    return 1
  fi
}

vendored_count() {
  local n=0 d
  shopt -s nullglob
  for d in "${VENDORED}"/*/; do
    if [[ -f "${d}SKILL.md" ]]; then
      n=$((n + 1))
    fi
  done
  shopt -u nullglob
  echo "${n}"
}

installed_count() {
  local n=0 d
  shopt -s nullglob
  for d in "${DEST}"/*/; do
    if [[ -f "${d}SKILL.md" ]]; then
      n=$((n + 1))
    fi
  done
  shopt -u nullglob
  echo "${n}"
}

if [[ "$(vendored_count)" -gt 0 ]]; then
  shopt -s nullglob
  for d in "${VENDORED}"/*/; do
    [[ -f "${d}SKILL.md" ]] || continue
    copy_one "${d%/}" "$(basename "${d}")"
  done
  shopt -u nullglob
  echo "install-cloud-skills: copied $(installed_count) vendored skills into ${DEST}"
  exit 0
fi

if [[ "$(installed_count)" -gt 0 ]]; then
  echo "install-cloud-skills: keeping $(installed_count) existing skills in ${DEST}"
  exit 0
fi

rm -rf "${WORKDIR}"
mkdir -p "${WORKDIR}"

tarball="${WORKDIR}/skills.tar.gz"
curl -fsSL "https://codeload.github.com/mattpocock/skills/tar.gz/${PINNED_SHA}" \
  -o "${tarball}"
tar -xzf "${tarball}" -C "${WORKDIR}"
root="$(find "${WORKDIR}" -mindepth 1 -maxdepth 1 -type d -name 'skills-*' | head -n 1)"
if [[ -z "${root}" ]]; then
  echo "install-cloud-skills: tarball had no repository root" >&2
  exit 1
fi

for rel in "${MATT_SKILLS[@]}"; do
  copy_one "${root}/${rel}" "$(basename "${rel}")"
done

if [[ -n "${GH_TOKEN:-}" ]]; then
  kb_src="${WORKDIR}/agent-env"
  git clone --depth 1 \
    "https://x-access-token:${GH_TOKEN}@github.com/vinsonyang798/agent-env.git" \
    "${kb_src}" >/dev/null 2>&1
  # Strip credentials from the clone remote so they are not left on disk.
  git -C "${kb_src}" remote set-url origin "${AGENT_ENV_REPO}"
  if [[ -f "${kb_src}/.cursor/skills/kb/SKILL.md" ]]; then
    copy_one "${kb_src}/.cursor/skills/kb" "kb"
  fi
else
  echo "install-cloud-skills: GH_TOKEN unset; skipped kb fallback" >&2
fi

rm -rf "${WORKDIR}"
echo "install-cloud-skills: installed $(installed_count) skills at ${PINNED_SHA} into ${DEST}"
