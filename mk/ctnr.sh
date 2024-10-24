#!/bin/sh -e
# [-d <deployment>=dev] [--push] [-r <registry-user>=quay.io/andykluger]

if [ "$1" = -h ] || [ "$1" = --help ]; then
  printf '%s\n' \
    'Build a container image' \
    'Args: [-d <deployment>=dev] [--push] [-r <registry-user>=quay.io/andykluger]' \
    1>&2
  exit 1
fi

#######################
### Configure Build ###
#######################

deployment=dev
registry_user=quay.io/andykluger
unset do_push
while [ "$1" = -d ] || [ "$1" = --push ] || [ "$1" = -r ]; do
  if [ "$1" = -d ];     then deployment=$2;    shift 2; fi
  if [ "$1" = -r ];     then registry_user=$2; shift 2; fi
  if [ "$1" = --push ]; then do_push=1;        shift;   fi
done

repo=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
set -x
version=$(git -C "$repo" describe)
branch=$(git -C "$repo" branch --show-current | sed 's/[^[:alnum:]\.\_\-]/_/g')
set +x

appname=colorcodebot
img=${registry_user}/${appname}-${deployment}-archlinux
ctnr=${img}-building

user=$appname
svcs_dir=/home/$user/svcs

iosevka_pkg='https://github.com/AndydeCleyre/archbuilder_iosevka/releases/download/31.6.1-ccb/ttf-iosevka-term-custom-git-1725883949-1-any.pkg.tar.zst'
today=$(date +%Y.%j)
tz="America/New_York"

base_img='docker.io/library/archlinux:base'
pkgs='silicon sops ttf-nerd-fonts-symbols-mono'
aur_pkgs='otf-openmoji s6 ttf-nanumgothic_coding'
aur_build_pkgs='mise-bin'
build_pkgs='base-devel git'

fat="/tmp/*"
fat="$fat /home/builder/.cache/* /root/.cache/*"
fat="$fat /home/builder/* /home/builder/.cargo"
fat="$fat /home/$user/.local/bin /root/.local/bin"
fat="$fat /var/cache/pacman/pkg/* /var/lib/pacman/sync/*"

#################
### Functions ###
#################

ctnr_run () {  # [-u|-b] <cmd> [<cmd-arg>...]
  _u=root
  if [ "$1" = -u ]; then
    _u=$user
    shift
  elif [ "$1" = -b ]; then
    _u=builder
    shift
  fi
  buildah run --user $_u "$ctnr" "$@"
}

ctnr_fetch () {  # [-u] <src-url-or-path> <dest-path>
  _u=root
  if [ "$1" = -u ]; then
    _u=$user
    shift
  elif [ "$1" = -b ]; then
    _u=builder
    shift
  fi
  buildah add --chown $_u "$ctnr" "$@"
}

ctnr_append () {  # [-u] <dest-path>
  unset _u
  if [ "$1" = -u ]; then _u=-u; shift; fi
  ctnr_run $_u sh -c "cat >>$1"
}

alias ctnr_pkg="ctnr_run pacman --noconfirm"
alias ctnr_pkg_upgrade="ctnr_pkg -Syu"
alias ctnr_pkg_add="ctnr_pkg -S --needed"
alias ctnr_pkg_del="ctnr_pkg -Rsn"

ctnr_mkuser () {  # <username>
  if ! ctnr_run id "$1" >/dev/null 2 >&1; then
    printf '%s\n' '' '>>> You may safely ignore the error above' '' >&2
    ctnr_run useradd -m "$1"
  fi
}

ctnr_trim () {
  # shellcheck disable=SC2046,SC2086
  for pkg in $build_pkgs $aur_build_pkgs $(ctnr_run pacman -Qqdtt); do
    ctnr_pkg_del "$pkg" || true
  done
  ctnr_run sh -c "rm -rf $fat"
}

ctnr_cd () {  # <path>
  buildah config --workingdir "$1" "$ctnr"
}

#############
### Build ###
#############

# Start fresh, or from a daily "jumpstart" image if available
buildah rm "$ctnr" 2>/dev/null || true
if ! buildah from -q --name "$ctnr" "$img-jumpstart:$today" 2>/dev/null; then
  buildah from -q --name "$ctnr" "$base_img"
  make_jumpstart_img=1
fi

# Set the timezone
ctnr_run ln -sf /usr/share/zoneinfo/$tz /etc/localtime

# Upgrade and install official packages
printf '%s\n' '' '>>> Upgrading and installing distro packages . . .' '' >&2
ctnr_pkg_upgrade
# shellcheck disable=SC2086
ctnr_pkg_add $pkgs $build_pkgs

# Add user
ctnr_mkuser $user

# Install AUR packages
printf '%s\n' '' '>>> Installing AUR packages . . .' '' >&2
ctnr_mkuser builder
ctnr_run rm -f /etc/sudoers.d/builder
printf '%s\n' 'builder ALL=(ALL) NOPASSWD: ALL' \
| ctnr_append /etc/sudoers.d/builder
ctnr_run -b git clone 'https://aur.archlinux.org/paru-bin' /tmp/paru-bin
ctnr_cd /tmp/paru-bin
ctnr_run -b makepkg --noconfirm -si
ctnr_cd /home/builder
# shellcheck disable=SC2086
ctnr_run -b paru -S --noconfirm --needed $aur_pkgs $aur_build_pkgs
ctnr_pkg_del paru-bin
ctnr_cd "/home/$user"

# Install Iosevka font
ctnr_fetch "$iosevka_pkg" /tmp
ctnr_run sh -c "pacman -U --noconfirm /tmp/ttf-iosevka-*.pkg.tar.zst"

# Rebuild font cache
ctnr_run -u fc-cache -r

# Copy app and svcs into container
tmp=$(mktemp -d)
# First, ready payloads:
git -C "$repo" archive HEAD:app >"$tmp/app.tar"
"$repo/mk/svcs.zsh" -d "$deployment" "$tmp/svcs"
if ctnr_run sh -c "[ -d /home/$user/venv ]"; then
  ctnr_run mv "/home/$user/venv" "/tmp/jumpstart_venv"
else
  printf '%s\n' '' '>>> You may safely ignore the error above' '' >&2
fi
# Second, burn down home:
ctnr_run rm -rf "$svcs_dir"
ctnr_run rm -rf "/home/$user"
# Third, deliver:
ctnr_fetch -u "$tmp/app.tar" /home/$user
ctnr_run -u chmod 0700 /home/$user
ctnr_fetch "$tmp/svcs" "$svcs_dir"
if ctnr_run sh -c '[ -d /tmp/jumpstart_venv ]'; then
  ctnr_run mv "/tmp/jumpstart_venv" /home/$user/venv
else
  printf '%s\n' '' '>>> You may safely ignore the error above' '' >&2
fi
ctnr_run chown -R "${user}:${user}" /home/$user
# Tidy up:
rm -rf "$tmp"

# Install extra syntax definitions
ctnr_run -u mkdir -p /home/$user/.config/silicon/themes
ctnr_run -u mkdir -p /home/$user/.config/silicon/syntaxes
ctnr_fetch -u "https://github.com/factor/sublime-factor/raw/master/Factor.sublime-syntax" "/home/$user/.config/silicon/syntaxes/"
ctnr_cd "/home/$user/.config/silicon"
ctnr_run -u silicon --build-cache
ctnr_cd "/home/$user"

# Install Python 3.11
ctnr_run -u mise install python@3.11

# Install Python modules
printf '%s\n' '' '>>> Installing PyPI packages . . .' '' >&2
ctnr_run -u /home/$user/.local/share/mise/installs/python/3.11/bin/python -m venv /home/$user/venv
ctnr_run /home/$user/venv/bin/pip install -qU pip wheel
ctnr_run /home/$user/venv/bin/pip install -Ur /home/$user/requirements.txt
if ctnr_run test -f "/home/${user}/${deployment}-requirements.txt"; then
  ctnr_run /home/$user/venv/bin/pip install -Ur "/home/${user}/${deployment}-requirements.txt"
fi
ctnr_run /home/$user/venv/bin/pip uninstall -qy pip wheel

# Save this stage as a daily "jumpstart" image
if [ "$make_jumpstart_img" ]; then
  printf '%s\n' '' '>>> Making jumpstart image . . .' '' >&2
  ctnr_trim
  buildah commit -q --rm "$ctnr" "$img-jumpstart:$today"
  buildah from -q --name "$ctnr" "$img-jumpstart:$today"
fi

# Install papertrail agent, if enabled
command -v yaml-get || exit 1
if [ "$(yaml-get -S -p 'svcs[name == papertrail].enabled' "$repo/vars.$deployment.yml")" = True ]; then
  ctnr_fetch \
    'https://github.com/papertrail/remote_syslog2/releases/download/v0.21/remote_syslog_linux_amd64.tar.gz' \
    /tmp
  ctnr_run tar xf \
    /tmp/remote_syslog_linux_amd64.tar.gz \
    -C /usr/local/bin \
    remote_syslog/remote_syslog \
    --strip-components 1
fi

###############
### Package ###
###############

# Cut the fat:
ctnr_trim

# Set default command
buildah config --cmd "s6-svscan $svcs_dir" "$ctnr"

# Press container as image
buildah rmi "$img:$today" "$img:latest" "$img:$version" 2>/dev/null || true
buildah tag "$(buildah commit -q --rm "$ctnr" "$img:latest")" "$img:$today" "$img:$version"
if [ "$branch" ]; then
  buildah tag "$img:latest" "$img:$branch"
fi

printf '%s\n' '' \
  '###################' \
  "### BUILT IMAGE ###" \
  '###################' '' \
  ">>> To decrypt credentials, you'll need to add or mount your age encryption keys as /root/.config/sops/age/keys.txt" \
  ">>> For the internal process supervision to work, you'll need to unmask /sys/fs/cgroup" \
  ">>> See start/podman.sh, which uses the host user's encryption keys and mounts a DB if present" ''

if [ "$do_push" ]; then
  podman push "$img-jumpstart:$today"
  podman push "$img:latest"
  podman push "$img:$today"
  podman push "$img:$version"
  if [ "$branch" ]; then
    podman push "$img:$branch"
  fi
fi
