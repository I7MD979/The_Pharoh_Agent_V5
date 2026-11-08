#!/usr/bin/env bash
# Step 6 — install the full HexStrike security toolset.
# Covers every tool listed by the HexStrike /health tools_status endpoint:
# apt packages, Go tools, pip CLIs, Ruby gems, GitHub release binaries and
# git-based tools. Idempotent and fault-tolerant: failures are logged and
# summarized, never abort the run. Proprietary/GUI tools (burpsuite, maltego,
# postman, insomnia, clair, falco) cannot be installed headless — skipped.
#
# Hard-won fixes baked in (see git history):
#   - wireshark-common debconf preseed (its setuid prompt blocks apt)
#   - ccache disabled for radare2 (ccache on this image cannot create executables)
#   - netexec needs Python >= 3.11 → installed into a dedicated python3.11 venv
#   - theHarvester pinned to 4.4.4 (newer releases require Python >= 3.11/3.14)
#   - prowler installed with --ignore-installed wfuzz (apt wfuzz metadata is
#     unparseable by modern pip and aborts dependency resolution)
#   - evil-winrm gem needs libkrb5-dev (gssapi native extension)
#   - hakrawler module path has no /v2 suffix anymore
#   - GOMEMLIMIT caps Go builds so they survive next to llama.cpp's RAM usage
set -uo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"
# common.sh enables `set -e` — turn it back off: partial failure must not
# abort the run, failures are collected in FAILS and summarized at the end.
set +e

FAILS=()
ok()   { log_ok "$*"; }
bad()  { log_error "$*"; FAILS+=("$*"); }
have() { command -v "$1" >/dev/null 2>&1; }

# gh_asset <repo> <asset-regex> <binary-name>
# Download latest GitHub release asset and install the binary to /usr/local/bin.
gh_asset() {
  local repo="$1" pattern="$2" name="$3" url tmp
  have "$name" && { ok "$name already installed"; return 0; }
  url="$(curl -fsSL "https://api.github.com/repos/$repo/releases/latest" \
        | jq -r '.assets[].browser_download_url' | grep -E "$pattern" | head -1)"
  [ -n "$url" ] || { bad "$name: no matching release asset for $repo"; return 1; }
  tmp="$(mktemp -d)"
  log_info "Downloading $name from $url"
  if ! curl -fsSL --retry 3 "$url" -o "$tmp/asset"; then bad "$name: download failed"; rm -rf "$tmp"; return 1; fi
  case "$url" in
    *.zip)     unzip -qo "$tmp/asset" -d "$tmp/x" ;;
    *.tar.gz|*.tgz) mkdir -p "$tmp/x" && tar xzf "$tmp/asset" -C "$tmp/x" ;;
    *.deb)     sudo dpkg -i "$tmp/asset" >/dev/null 2>&1 || sudo apt-get -f install -y ;;
    *)         mkdir -p "$tmp/x" && cp "$tmp/asset" "$tmp/x/$name" ;;
  esac
  if [ "$name" = "ghidra" ]; then
    local gdir
    gdir="$(find "$tmp/x" -maxdepth 1 -type d -name 'ghidra*' | head -1)"
    if [ -n "$gdir" ]; then
      sudo rm -rf /opt/ghidra && sudo mv "$gdir" /opt/ghidra
      printf '#!/bin/bash\nexec /opt/ghidra/ghidraRun "$@"\n' | sudo tee /usr/local/bin/ghidra >/dev/null
      sudo chmod +x /usr/local/bin/ghidra /opt/ghidra/ghidraRun 2>/dev/null
      ok "ghidra installed to /opt/ghidra"; rm -rf "$tmp"; return 0
    fi
    bad "ghidra: layout unexpected"; rm -rf "$tmp"; return 1
  fi
  local bin
  bin="$(find "$tmp/x" -type f -name "$name*" -perm -u+x 2>/dev/null | head -1)"
  [ -n "$bin" ] || bin="$(find "$tmp/x" -type f -name "$name*" | head -1)"
  if [ -n "$bin" ]; then
    sudo install -m 0755 "$bin" "/usr/local/bin/$name"
    ok "$name installed"; rm -rf "$tmp"; return 0
  fi
  have "$name" && { ok "$name installed via package"; rm -rf "$tmp"; return 0; }
  bad "$name: binary not found in asset"; rm -rf "$tmp"; return 1
}

# ============================================================================
log_banner "1/7 apt packages"
export DEBIAN_FRONTEND=noninteractive
# Pre-answer the wireshark-common debconf question so it cannot block the install.
echo "wireshark-common wireshark-common/install-setuid boolean false" | sudo debconf-set-selections
sudo apt-get update -qq || log_warn "apt-get update failed — continuing with cache"
APT_PKGS=(
  aircrack-ng amass arp-scan autopsy binwalk bulk-extractor checksec
  dirsearch dnsenum dotdotpwn enum4linux exploitdb foremost hashcat
  hashcat-utils hash-identifier hashpump httpie kismet medusa
  metasploit-framework nbtscan ophcrack-cli outguess patator radare2
  recon-ng responder ruby-full samba-client scalpel sleuthkit smbmap
  steghide testdisk theharvester tshark wireshark-common wfuzz wpscan
  xsser zaproxy commix libimage-exiftool-perl default-jre-headless
  ruby-dev build-essential libssl-dev libcurl4-openssl-dev libxml2-dev
  libxslt1-dev zlib1g-dev perl libkrb5-dev libgmp-dev
)
AVAIL=()
for p in "${APT_PKGS[@]}"; do
  if apt-cache show "$p" >/dev/null 2>&1; then AVAIL+=("$p"); else log_warn "no apt package: $p"; fi
done
if sudo apt-get install -y --no-install-recommends "${AVAIL[@]}"; then
  ok "apt batch installed (${#AVAIL[@]} packages)"
else
  log_warn "apt batch failed — retrying one by one"
  for p in "${AVAIL[@]}"; do
    sudo apt-get install -y --no-install-recommends "$p" >/dev/null 2>&1 \
      && ok "apt: $p" || bad "apt: $p"
  done
fi

# ============================================================================
log_banner "2/7 Go tools (GOBIN=/usr/local/bin)"
export PATH="$PATH:/snap/bin"
declare -A GO_TOOLS=(
  [subfinder]="github.com/projectdiscovery/subfinder/v2/cmd/subfinder@latest"
  [httpx]="github.com/projectdiscovery/httpx/cmd/httpx@latest"
  [katana]="github.com/projectdiscovery/katana/cmd/katana@latest"
  [ffuf]="github.com/ffuf/ffuf/v2@latest"
  [dalfox]="github.com/hahwul/dalfox/v2@latest"
  [hakrawler]="github.com/hakluke/hakrawler@latest"
  [jaeles]="github.com/jaeles-project/jaeles@latest"
  [gau]="github.com/tomnomnom/gau/v2/cmd/gau@latest"
  [waybackurls]="github.com/tomnomnom/waybackurls@latest"
  [qsreplace]="github.com/tomnomnom/qsreplace@latest"
  [anew]="github.com/tomnomnom/anew@latest"
)
for t in "${!GO_TOOLS[@]}"; do
  have "$t" && { ok "$t already installed"; continue; }
  log_info "go install $t"
  if sudo -E env GOBIN=/usr/local/bin GOPATH="$HOME/go" GOFLAGS=-mod=mod GOMEMLIMIT=8GiB \
       go install "${GO_TOOLS[$t]}" >/dev/null 2>&1; then
    ok "go: $t"
  else
    bad "go: $t"
  fi
done

# ============================================================================
log_banner "3/7 pip CLIs (system python → /usr/local/bin)"
sudo pip3 install --upgrade pip >/dev/null 2>&1 || true
PIP_PKGS=(pwntools ROPGadget ropper volatility3 arjun uro checkov
          kube-hunter sherlock-project social-analyzer censys shodan)
for p in "${PIP_PKGS[@]}"; do
  log_info "pip install $p"
  if sudo pip3 install --quiet "$p" >/dev/null 2>&1; then ok "pip: $p"; else bad "pip: $p"; fi
done

# ============================================================================
log_banner "4/7 Ruby gems"
for g in zsteg one_gadget; do
  log_info "gem install $g"
  if sudo gem install "$g" --no-document >/dev/null 2>&1; then ok "gem: $g"; else bad "gem: $g"; fi
done

# ============================================================================
log_banner "5/7 GitHub release binaries"
gh_asset "epi052/feroxbuster"      'linux-x86_64.*\.zip$'   feroxbuster || true
gh_asset "RustScan/RustScan"       '_amd64\.deb$'           rustscan || true
gh_asset "Sh1Yo/x8"                'linux'                  x8 || true
gh_asset "io12/pwninit"            '/pwninit$'              pwninit || true
gh_asset "tenable/terrascan"       'Linux_x86_64\.tar\.gz$' terrascan || true
gh_asset "aquasecurity/kube-bench" 'linux_amd64\.tar\.gz$'  kube-bench || true
gh_asset "aquasecurity/trivy"      'Linux-64bit\.tar\.gz$'  trivy || true
gh_asset "NationalSecurityAgency/ghidra" 'PUBLIC.*\.zip$'   ghidra || true

# ============================================================================
log_banner "6/7 git-based tools (/opt + wrappers)"
git_tool() { # <name> <repo-url> <wrapper-cmd>
  local name="$1" url="$2" wrapper="${3:-}"
  local dest="/opt/$name"
  [ -d "$dest" ] || sudo git clone --depth 1 "$url" "$dest" >/dev/null 2>&1 \
    || { bad "git clone $name"; return 1; }
  if [ -n "$wrapper" ]; then
    printf '#!/bin/bash\n%s "$@"\n' "$wrapper" | sudo tee "/usr/local/bin/$name" >/dev/null
    sudo chmod +x "/usr/local/bin/$name"
  fi
  ok "$name → $dest"
}
git_tool enum4linux-ng https://github.com/cddmp/enum4linux-ng.git \
  "cd /opt/enum4linux-ng && python3 enum4linux-ng.py" || true
sudo pip3 install --quiet -r /opt/enum4linux-ng/requirements.txt >/dev/null 2>&1 || true
git_tool jwt_tool https://github.com/ticarpi/jwt_tool.git \
  "python3 /opt/jwt_tool/jwt_tool.py" || true
sudo pip3 install --quiet -r /opt/jwt_tool/requirements.txt >/dev/null 2>&1 || true
git_tool paramspider https://github.com/devanshbatham/paramspider.git \
  "python3 /opt/paramspider/paramspider.py" || true
git_tool docker-bench-security https://github.com/docker/docker-bench-security.git || true
git_tool libc-database https://github.com/niklasb/libc-database.git || true
# stegsolve (jar) — best effort from GitHub mirror
if ! have stegsolve; then
  if curl -fsSL -m 60 "https://github.com/Giotino/stegsolve/releases/download/v1.4/StegSolve.jar" -o /tmp/stegsolve.jar 2>/dev/null \
     || curl -fsSL -m 60 "https://github.com/eugenekolo/sec-tools/raw/master/stego/stegsolve/stegsolve/stegsolve.jar" -o /tmp/stegsolve.jar 2>/dev/null; then
    sudo mv /tmp/stegsolve.jar /opt/stegsolve.jar
    printf '#!/bin/bash\nexec java -jar /opt/stegsolve.jar "$@"\n' | sudo tee /usr/local/bin/stegsolve >/dev/null
    sudo chmod +x /usr/local/bin/stegsolve
    ok "stegsolve"
  else
    bad "stegsolve: jar download failed"
  fi
fi

# ============================================================================
log_banner "7/7 stragglers (source builds / special cases)"

# Fix Go module cache ownership if earlier root runs broke it, then retry hakrawler
sudo chown -R "$STACK_USER:$STACK_USER" "$STACK_HOME/go" 2>/dev/null || true
if ! have hakrawler; then
  log_info "go install hakrawler (retry)"
  sudo -E env GOBIN=/usr/local/bin GOPATH="$HOME/go" GOFLAGS=-mod=mod \
    go install github.com/hakluke/hakrawler@latest >/dev/null 2>&1 \
    && ok "go: hakrawler" || bad "go: hakrawler"
fi

# metasploit via the official Rapid7 installer (not in Ubuntu 22.04 repos)
if ! have msfconsole; then
  log_info "Installing Metasploit via Rapid7 msfinstall…"
  if curl -fsSL https://raw.githubusercontent.com/rapid7/metasploit-omnibus/master/config/templates/metasploit-framework-wrappers/msfupdate.erb \
       -o /tmp/msfinstall && sudo bash /tmp/msfinstall >/dev/null 2>&1; then
    ok "metasploit-framework"
  else
    bad "metasploit-framework (msfinstall)"
  fi
fi

# radare2 — build from source (not packaged for jammy). ccache on this image
# is broken ("ccache gcc cannot create executables") → disable it explicitly.
if ! have radare2 && ! have r2; then
  log_info "Building radare2 from source (this takes a few minutes)…"
  if [ ! -d /opt/radare2 ]; then
    sudo git clone --depth 1 https://github.com/radareorg/radare2 /opt/radare2 >/dev/null 2>&1
  fi
  sudo git config --global --add safe.directory /opt/radare2 2>/dev/null || true
  if [ -d /opt/radare2 ] && ( cd /opt/radare2 && sudo env CCACHE_DISABLE=1 CC=gcc CXX=g++ bash sys/install.sh >/tmp/r2-build.log 2>&1 ); then
    ok "radare2"
  else
    bad "radare2 (source build — see /tmp/r2-build.log)"
  fi
fi

# zaproxy — GitHub release tarball → /opt + wrapper
if ! have zaproxy && ! have zap.sh; then
  log_info "Installing OWASP ZAP from GitHub release…"
  zurl="$(curl -fsSL https://api.github.com/repos/zaproxy/zaproxy/releases/latest \
        | jq -r '.assets[].browser_download_url' | grep -E 'Linux\.tar\.gz$' | head -1)"
  if [ -n "$zurl" ] && curl -fsSL "$zurl" -o /tmp/zap.tar.gz; then
    sudo rm -rf /opt/zaproxy && sudo mkdir -p /opt/zaproxy
    sudo tar xzf /tmp/zap.tar.gz -C /opt/zaproxy --strip-components=1
    printf '#!/bin/bash\nexec /opt/zaproxy/zap.sh "$@"\n' | sudo tee /usr/local/bin/zaproxy >/dev/null
    sudo chmod +x /usr/local/bin/zaproxy /opt/zaproxy/zap.sh
    ok "zaproxy"
  else
    bad "zaproxy (download)"
  fi
fi

# gems needing build tools (installed in stage 1): wpscan, evil-winrm
for g in wpscan evil-winrm; do
  have "${g//_/-}" && continue
  log_info "gem install $g"
  sudo gem install "$g" --no-document >/dev/null 2>&1 && ok "gem: $g" || bad "gem: $g"
done

# netexec — requires Python >= 3.11; jammy ships 3.10, so give it its own venv
if ! have nxc; then
  if ! command -v python3.11 >/dev/null 2>&1; then
    log_info "Installing Python 3.11 (deadsnakes) for netexec…"
    sudo add-apt-repository -y ppa:deadsnakes/ppa >/dev/null 2>&1
    sudo apt-get update -qq >/dev/null 2>&1
    sudo apt-get install -y --no-install-recommends python3.11 python3.11-venv >/dev/null 2>&1
  fi
  if command -v python3.11 >/dev/null 2>&1; then
    sudo python3.11 -m venv /opt/nxc-venv 2>/dev/null \
      && sudo /opt/nxc-venv/bin/pip install --quiet --upgrade pip >/dev/null 2>&1 \
      && sudo /opt/nxc-venv/bin/pip install --quiet netexec >/dev/null 2>&1 \
      && sudo ln -sf /opt/nxc-venv/bin/nxc /usr/local/bin/nxc \
      && sudo ln -sf /opt/nxc-venv/bin/nxc /usr/local/bin/netexec \
      && ok "netexec (python3.11 venv)" || bad "netexec (venv install)"
  else
    bad "netexec (python3.11 unavailable)"
  fi
fi

# pip-from-git installs (not usable from PyPI on python 3.10)
declare -A GIT_PIP=(
  [scout-suite]="git+https://github.com/nccgroup/ScoutSuite.git"
  [autorecon]="git+https://github.com/Tib3rius/AutoRecon.git"
  # theHarvester master needs Python >= 3.14; 4.4.4 is the last 3.10-compatible release
  [theHarvester]="git+https://github.com/laramies/theHarvester.git@4.4.4"
)
for p in "${!GIT_PIP[@]}"; do
  have "$(echo "$p" | tr 'A-Z' 'a-z')" && continue
  log_info "pip install $p (from git)"
  sudo pip3 install --quiet "${GIT_PIP[$p]}" >/dev/null 2>&1 && ok "pip: $p" || bad "pip: $p (git)"
done

# prowler — apt's wfuzz ships metadata modern pip cannot parse; keep wfuzz, take prowler
have prowler || { sudo pip3 install --quiet --ignore-installed wfuzz prowler >/dev/null 2>&1 \
  && ok "pip: prowler" || bad "pip: prowler"; }

# graphql-cop is a script repo, not a pip package
if [ ! -d /opt/graphql-cop ]; then
  if sudo git clone --depth 1 https://github.com/dolevf/graphql-cop.git /opt/graphql-cop >/dev/null 2>&1; then
    [ -f /opt/graphql-cop/requirements.txt ] && \
      sudo pip3 install --quiet -r /opt/graphql-cop/requirements.txt >/dev/null 2>&1
    gcmain="$(sudo ls /opt/graphql-cop/*.py 2>/dev/null | head -1)"
    [ -n "$gcmain" ] && printf '#!/bin/bash\npython3 %s "$@"\n' "$gcmain" | sudo tee /usr/local/bin/graphql-cop >/dev/null \
      && sudo chmod +x /usr/local/bin/graphql-cop
    ok "graphql-cop"
  else
    bad "graphql-cop (clone)"
  fi
fi

# amass via Go (not in jammy repos)
if ! have amass; then
  log_info "go install amass v4"
  sudo -E env GOBIN=/usr/local/bin GOPATH="$HOME/go" GOFLAGS=-mod=mod GOMEMLIMIT=8GiB \
    go install github.com/owasp-amass/amass/v4/...@master >/dev/null 2>&1 \
    && ok "go: amass" || bad "go: amass"
fi

# git-clone tools with wrapper scripts
git_tool responder  https://github.com/lgandx/Responder.git          "cd /opt/responder && sudo python3 Responder.py" || true
git_tool commix     https://github.com/commixproject/commix.git      "python3 /opt/commix/commix.py" || true
git_tool xsser      https://github.com/epsylon/xsser.git             "python3 /opt/xsser/xsser/xsser" || true
git_tool dotdotpwn  https://github.com/wireghoul/dotdotpwn.git       "perl /opt/dotdotpwn/dotdotpwn.pl" || true
git_tool enum4linux https://github.com/CiscoCXSecurity/enum4linux.git "perl /opt/enum4linux/enum4linux.pl" || true
git_tool spiderfoot https://github.com/smicallef/spiderfoot.git      "cd /opt/spiderfoot && python3 sf.py" || true
[ -f /opt/spiderfoot/requirements.txt ] && \
  sudo pip3 install --quiet -r /opt/spiderfoot/requirements.txt >/dev/null 2>&1 || true
# exploitdb / searchsploit
if [ ! -d /opt/exploitdb ]; then
  sudo git clone --depth 1 https://gitlab.com/exploit-database/exploitdb.git /opt/exploitdb >/dev/null 2>&1 \
    && sudo ln -sf /opt/exploitdb/searchsploit /usr/local/bin/searchsploit \
    && ok "exploitdb/searchsploit" || bad "exploitdb"
fi
# hashcat-utils — tiny C tools, just make
if ! have cap2hccapx.bin && [ ! -d /opt/hashcat-utils ]; then
  if sudo git clone --depth 1 https://github.com/hashcat/hashcat-utils.git /opt/hashcat-utils >/dev/null 2>&1 \
     && sudo make -s -C /opt/hashcat-utils/src >/dev/null 2>&1; then
    for b in /opt/hashcat-utils/src/*.bin; do sudo ln -sf "$b" "/usr/local/bin/$(basename "$b")"; done
    ok "hashcat-utils"
  else
    bad "hashcat-utils"
  fi
fi
# hashpump — needs g++ + libssl
if ! have hashpump; then
  if sudo git clone --depth 1 https://github.com/bwall/HashPump /opt/hashpump >/dev/null 2>&1 \
     && sudo make -s -C /opt/hashpump >/dev/null 2>&1 \
     && sudo make -s -C /opt/hashpump install >/dev/null 2>&1; then
    ok "hashpump"
  else
    bad "hashpump"
  fi
fi

# ============================================================================
log_banner "Summary"
if [ "${#FAILS[@]}" -eq 0 ]; then
  log_ok "All tool groups installed without failures."
else
  log_warn "${#FAILS[@]} item(s) failed (usually upstream/package issues):"
  printf '  - %s\n' "${FAILS[@]}"
fi
log_info "Proprietary/GUI tools intentionally skipped: burpsuite maltego postman insomnia clair falco"
exit 0
