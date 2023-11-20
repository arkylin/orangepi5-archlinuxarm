#!/bin/bash -e

# The script would run as two different roles:
# 1 (role=parent, default). The one that user starts runs in the parent namespace, it spawns a child with unshared user,pid,mount namespaces
# 2 (role=child). The second one runs in the child namespace, it sets up mounts 

# functions
help() {
    echo '
Build ArchLinux ARM images on an x86_64 host, rootless

./cross_nobuild.sh

  --install <pkg>           install the package into target image, can be specified multiple times
  --install-kernel <pkg>    install the kernel package into target image, also create booting configurations
  --install-bootstrap <pkg> install the package into target image at bootstrap stage, can be specified multiple times
  --role parent/child
  --uuid-root <uuid>        uuid to be used for root ext4 fs
  --uuid-boot <uuid>        uuid to be used for boot fat32 fs, only first 8 chars used
  --build-id <id>           a string id for the build
  --freeze-rkloader         freeze versions of rkloader and do not update them
  --local-mirror            download pkgs from a local pacoloco mirror
  --help                    print this message and early quit

WARNING: CLI arguments are mostly for internal usage, you should not rely on its behaviour
WARNING: This script is written for Ubuntu22.04, the exact environment that Github Actions provide
'
}
dl() { # 1: url 2: output
    echo "Downloading '$2' <= '$1'" >&2
    if [[ "$2" ]]; then
        curl -qgb "" -fL --retry 3 --retry-delay 3 -o "$2" "$1"
    else
        curl -qgb "" -fL --retry 3 --retry-delay 3 "$1"
    fi
    echo "Downloaded '$2' <= '$1'" >&2
}

dump_binary_from_repo() { # 1: repo url, 2: repo name, 3: pkgname, 4: local bin, 5: source bin
    dl "$1/$2".db cache/repo.db
    local desc=$(tar -xOf cache/repo.db --wildcards "$3"'-*/desc')
    local names=($(sed -n '/%NAME%/{n;p;}' <<< "${desc}"))
    case ${#names[@]} in
    0)
        echo "Failed to find package '$3' in repo '$1"
        return 1
    ;;
    1)
        local ver=$(sed -n '/%VERSION%/{n;p;}' <<< "${desc}")
        local pkg=$(sed -n '/%FILENAME%/{n;p;}' <<< "${desc}")
    ;;
    *)
        local vers=($(sed -n '/%VERSION%/{n;p;}' <<< "${desc}"))
        local pkgs=($(sed -n '/%FILENAME%/{n;p;}' <<< "${desc}"))
        local id=0
        local name
        for name in "${names[@]}"; do
            if [[ "${name}" == "$3" ]]; then
                break
            fi
            local id=$(( id + 1 ))
        done
        local ver="${vers[${id}]}"
        local pkg="${pkgs[${id}]}"
    ;;
    esac
    if [[ ! -f bin/"$4-${ver}" ]]; then
        rm bin/"$4"-* || true
        dl "$1/${pkg}" cache/"${pkg}"
        tar -xOf cache/"${pkg}" "$5" > bin/"$4-${ver}".temp
        mv bin/"$4-${ver}"{.temp,}
    fi
    chmod +x bin/"$4-${ver}"
    ln -sf "$4-${ver}" bin/"$4"
}

cleanup_parent() {
    echo "=> Cleaning up before exiting..."
    # The root mount only lives inside the child namespace, no need to umount
    rm -rf cache/root
    if [[ -n "${child_pid}" ]]; then
        wait "${child_pid}"
    fi
}

cleanup_child() {
    :
}

pacman_could_retry() {
    if ! bin/pacman "$@"; then
        echo "Warning: pacman command failed to execute correctly, retry once"
        bin/pacman "$@"
    fi
}

get_uid_gid() {
    uid=$(id --user)
    gid=$(id --group)
}

check_identity_root() {
    get_uid_gid
    if [[ "${uid}" != 0 ]]; then
        echo "ERROR: Must run as root (UID = 0)"
        exit 1
    fi
    if [[ "${gid}" != 0 ]]; then
        echo "ERROR: Must run as GID = 0"
        exit 1
    fi
}

check_identity_non_root() {
    get_uid_gid
    if [[ "${uid}" == 0 ]]; then
        echo "ERROR: Not allowed to run as root (UID = 0)"
        exit 1
    fi
    if [[ "${gid}" == 0 ]]; then
        echo "ERROR: Not allowed to run as GID = 0"
        exit 1
    fi
}

check_identity_map_root() {
    check_identity_root
    if touch /sys/sys_write_test; then
        echo "Child: ERROR: We can write to /sys, refuse to continue as real root"
        exit 1
    fi
}

config_repos() {
    if [[ "${pkg_from_local_mirror}" ]]; then
        mirror_archlinux=${mirror_archlinux:-http://repo.lan:9129/repo/archlinux}
        mirror_archlinuxarm=${mirror_alarm:-http://repo.lan:9129/repo/archlinuxarm}
        mirror_archlinuxcn=${mirror_archlinuxcn:-http://repo.lan:9129/repo/archlinuxcn_x86_64}
        mirror_7Ji=${mirror_7Ji:-http://repo.lan/github-mirror}
    else
        mirror_archlinux=${mirror_archlinux:-https://geo.mirror.pkgbuild.com}
        mirror_archlinuxarm=${mirror_alarm:-http://mirror.archlinuxarm.org}
        mirror_archlinuxcn=${mirror_archlinuxcn:-https://opentuna.cn/archlinuxcn}
        mirror_7Ji=${mirror_7Ji:-https://github.com/7Ji/archrepo/releases/download}
    fi
    # Mainly for pacman-static
    repo_url_archlinuxcn_x86_64="${mirror_archlinuxcn}"/x86_64
    # For base system packages
    repo_url_alarm_aarch64="${mirror_archlinuxarm}"/aarch64/'$repo'
    # For kernels and other stuffs
    repo_url_7Ji_aarch64="${mirror_7Ji}"/aarch64
}

prepare_host_dirs() {
    rm -rf cache
    mkdir -p {bin,cache/root,out,src/{rkloader,pkg}}
}

get_rkloaders() {
    # Get rkloaders
    if [[ "${freeze_rkloaders}" ]]; then
        echo "=> Updating of RKloaders skipped"
        rkloaders=()
        for rkloader in src/rkloader/*; do
            rkloaders+=("${rkloader##*/}")
        done
    else
        echo "=> Updating RKloaders"
        rkloader_parent=https://github.com/7Ji/orangepi5-rkloader/releases/download/nightly
        rkloaders=($(dl "${rkloader_parent}"/list))
        for rkloader in "${rkloaders[@]}"; do
            if [[ ! -f src/rkloader/"${rkloader}" ]]; then
                dl "${rkloader_parent}/${rkloader}" src/rkloader/"${rkloader}".temp
                mv src/rkloader/"${rkloader}"{.temp,}
            fi
        done
        for rkloader in src/rkloader/*; do
            rkloader_local="${rkloader##*/}"
            latest=''
            for rkloader_cmp in "${rkloaders[@]}"; do
                if [[ "${rkloader_local}" == "${rkloader_cmp}" ]]; then
                    latest='yes'
                    break
                fi
            done
            if [[ -z "${latest}" ]]; then
                rm -f "${rkloader}"
            fi
        done
        echo "=> Updated RKloaders"
    fi
}

prepare_pacman_static() {
    dump_binary_from_repo "${repo_url_archlinuxcn_x86_64}" archlinuxcn pacman-static pacman usr/bin/pacman-static 
}

mount_root() {
    mount tmpfs-root cache/root -t tmpfs -o mode=0755,nosuid 
    mkdir -p cache/root/{boot,dev/{pts,shm},etc/pacman.d,proc,run,sys,tmp,var/{cache/pacman/pkg,lib/pacman,log}}
    chmod 1777 cache/root/{dev/shm,tmp}
    chmod 555 cache/root/{proc,sys}
    mount proc cache/root/proc -t proc -o nosuid,noexec,nodev
    mount devpts cache/root/dev/pts -t devpts -o mode=0620,gid=5,nosuid,noexec
    for node in full null random tty urandom zero; do
        devnode=cache/root/dev/"${node}"
        touch "${devnode}"
        mount /dev/"${node}" "${devnode}" -o bind
    done
    ln -s /proc/self/fd/2 cache/root/dev/stderr
    ln -s /proc/self/fd/1 cache/root/dev/stdout
    ln -s /proc/self/fd/0 cache/root/dev/stdin
    ln -s /proc/kcore cache/root/dev/core
    ln -s /proc/self/fd cache/root/dev/fd
    ln -s pts/ptmx cache/root/dev/ptmx
    ln -s $(readlink -f /dev/stdout) cache/root/dev/console
}

umount_root_sub() {
    chroot cache/root killall -s KILL gpg-agent dirmngr || true
    for node in full null random tty urandom zero pts; do
        umount --lazy cache/root/dev/"${node}"
    done
    umount --lazy cache/root/proc
    rm -rf cache/root/dev/*
}

prepare_pacman_configs() {
    # Create temporary pacman config
    pacman_config="
RootDir      = cache/root
DBPath       = cache/root/var/lib/pacman/
CacheDir     = src/pkg/
LogFile      = cache/root/var/log/pacman.log
GPGDir       = cache/root/etc/pacman.d/gnupg/
HookDir      = cache/root/etc/pacman.d/hooks/
Architecture = aarch64"
    pacman_mirrors="
[core]
Server = ${repo_url_alarm_aarch64}
[extra]
Server = ${repo_url_alarm_aarch64}
[alarm]
Server = ${repo_url_alarm_aarch64}
[aur]
Server = ${repo_url_alarm_aarch64}
[7Ji]
Server = ${repo_url_7Ji_aarch64}"

    echo "[options]${pacman_config}
SigLevel = Never${pacman_mirrors}" > cache/pacman-loose.conf

    echo "[options]${pacman_config}
SigLevel = DatabaseOptional${pacman_mirrors}" > cache/pacman-strict.conf
}

enable_network() {
    cat /etc/resolv.conf > cache/resolv.conf
    mount cache/resolv.conf cache/root/etc/resolv.conf -o bind
}

disable_network() {
    umount cache/root/etc/resolv.conf
}

bootstrap_root() {
    pacman_could_retry -Sy --config cache/pacman-loose.conf --noconfirm "${install_pkgs_bootstrap[@]}"
    echo '[7Ji]
Server = https://github.com/7Ji/archrepo/releases/download/$arch' >> cache/root/etc/pacman.conf
    enable_network
    chroot cache/root /bin/bash -c "pacman-key --init && pacman-key --populate"
    disable_network
}

install_mkinitcpio() {
    # This is a huge hack, basically we disable post-transaction hook that would 
    # call mkinitcpio, so mkinitcpio won't be called in target, then we run 
    # mkinitcpio manually, with compression disabled, and also only create
    # fallback initcpio.
    # We then compress the initcpio on host.
    # This avoids the performance penalty if mkinitcpio runs with compression in
    # target, as qemu is not that efficient
    pacman_could_retry -S --config cache/pacman-strict.conf --noconfirm mkinitcpio
    local mkinitcpio_conf=cache/root/etc/mkinitcpio.conf
    cp "${mkinitcpio_conf}"{,.pacsave}
    echo 'COMPRESSION=cat' >> "${mkinitcpio_conf}"
    local mkinitcpio_install_hook=cache/root/usr/share/libalpm/hooks/90-mkinitcpio-install.hook
    mv "${mkinitcpio_install_hook}"{,.pacsave}
}

unhack_mkinitcpio() {
    local mkinitcpio_conf=cache/root/etc/mkinitcpio.conf
    local mkinitcpio_install_hook=cache/root/usr/share/libalpm/hooks/90-mkinitcpio-install.hook
    mv "${mkinitcpio_conf}"{.pacsave,}
    mv "${mkinitcpio_install_hook}"{.pacsave,}
}

setup_kernel() {
    if [[ ${#install_pkgs_kernel[@]} == 0 ]]; then
        return
    fi
    local kernel
    for kernel in "${install_pkgs_kernel[@]}"; do
        local preset=cache/root/etc/mkinitcpio.d/"${kernel}".preset
        cp "${preset}"{,.pacsave}
        printf '\nPRESETS=(fallback)\n' >> "${preset}"
    done
    for module_dir in cache/root/usr/lib/modules/*; do
        cp "${module_dir}"/vmlinuz cache/root/boot/vmlinuz-$(<"${module_dir}"/pkgbase)
    done
    chroot cache/root mkinitcpio -P
    # Manually compress
    for kernel in "${install_pkgs_kernel[@]}"; do
        mv cache/root/etc/mkinitcpio.d/"${kernel}".preset{.pacsave,}
        local initramfs=cache/root/boot/initramfs-"${kernel}"-fallback.img
        zstd -T0 "${initramfs}"
        mv "${initramfs}"{.zst,}
    done
}

setup_extlinux() {
    # Setup configuration
    local conf=cache/extlinux.conf
    echo "DEFAULT ${install_pkgs_kernel[0]}" > "${conf}"
    local kernel
    for kernel in "${install_pkgs_kernel[@]}"; do
        printf \
            "LABEL\t%s\n\tLINUX\t/%s\n\tINITRD\t/%s\n\tFDT\t/%s\n\tAPPEND\t%s\n" \
            "${kernel}" \
            "vmlinuz-${kernel}" \
            "initramfs-${kernel}-fallback.img" \
            "dtbs/${kernel}/rockchip/rk3588s-orangepi-5.dtb" \
            "root=UUID=${uuid_root} rw" >> "${conf}"
    done
    install -DTm644 cache/{,root/boot/extlinux/}extlinux.conf
}

install_pkgs() {
    pacman_could_retry -S --config cache/pacman-strict.conf --noconfirm "${install_pkgs_kernel[@]}" "${install_pkgs_normal[@]}"
}

cleanup_pkgs() {
    bin/pacman -Sc --config cache/pacman-strict.conf --noconfirm
}

setup_root() {
    # /etc/fstab
    echo "# root partition with ext4 on SDcard / USB drive
UUID=${uuid_root}	/	ext4	rw,noatime	0 1
# boot partition with vfat on SDcard / USB drive
UUID=${uuid_boot_specifier}	/boot	vfat	rw,noatime	0 2" >>  cache/root/etc/fstab
    # Timezone
    ln -sf "/usr/share/zoneinfo/UTC" cache/root/etc/localtime
    # Locale
    sed -i 's/^#\(en_US.UTF-8  \)$/\1/g' cache/root/etc/locale.gen
    echo 'LANG=en_US.UTF-8' > cache/root/etc/locale.conf

    # Network
    echo alarm > cache/root/etc/hostname
    printf '127.0.0.1\tlocalhost\n::1\t\tlocalhost\n' >> cache/root/etc/hosts
    printf '[Match]\nName=eth* en*\n\n[Network]\nDHCP=yes\nDNSSEC=no\n' > cache/root/etc/systemd/network/20-wired.network

    # Users
    local sudoers=cache/root/etc/sudoers
    chmod o+w "${sudoers}"
    sed -i 's|^# %wheel ALL=(ALL:ALL) ALL$|%wheel ALL=(ALL:ALL) ALL|g' "${sudoers}"
    chmod o-w "${sudoers}"

    # Actual resolv
    ln -sf /run/systemd/resolve/resolv.conf cache/root/etc/resolv.conf

    # Temporary hack before https://gitlab.archlinux.org/archlinux/mkinitcpio/mkinitcpio/-/issues/218 is resolved
    sed -i 's/^HOOKS=(base udev autodetect modconf kms keyboard keymap consolefont block filesystems fsck)$/HOOKS=(base udev autodetect modconf keyboard keymap consolefont block filesystems fsck)/'  cache/root/etc/mkinitcpio.conf

    # Things that need to done inside the root
    chroot cache/root /bin/bash -ec 'locale-gen
systemctl enable systemd-{network,resolve,timesync}d usb2host sshd
useradd -g wheel -m alarm
printf "%s\n" alarm_please_change_me alarm_please_change_me | passwd alarm'
}

archive_root() {
    local archive=out/"${build_id}"-root.tar
    (
        cd cache/root
        bsdtar --acls --xattrs -cpf - *
    ) > "${archive}".temp
    mv "${archive}"{.temp,}
}

image_disk() {
    local image=out/"${build_id}"-base.img
    local temp_image="${image}".temp
    rm -f "${temp_image}"
    truncate -s 2G "${temp_image}"
    echo 'label: gpt
        start=8192, size=204800, type=C12A7328-F81F-11D2-BA4B-00A0C93EC93B
        start=212992, size=3979264, type=B921B045-1DF0-41C3-AF44-4C6F280D3FAE' |
            sfdisk "${temp_image}"
    dd if=cache/boot.img of="${temp_image}" bs=1M seek=4 conv=notrunc
    dd if=cache/root.img of="${temp_image}" bs=1M seek=104 conv=notrunc
    sync
    mv "${temp_image}" "${image}"
}

image_rkloader() {
    suffixes=(root.tar base.img)
    local table='label: gpt
        first-lba: 34
        start=64, size=960, type=8DA63339-0007-60C0-C436-083AC8230908, name="idbloader"
        start=1024, size=6144, type=8DA63339-0007-60C0-C436-083AC8230908, name="uboot"
        start=8192, size=204800, type=C12A7328-F81F-11D2-BA4B-00A0C93EC93B, name="alarmboot"
        start=212992, size=3979264, type=B921B045-1DF0-41C3-AF44-4C6F280D3FAE, name="alarmroot"'
    local base_image=out/"${build_id}"-base.img
    local rkloader model image temp_image suffix fdt
    for rkloader in "${rkloaders[@]}"; do
        model=${rkloader##*pi-}
        model=${model%%-bl31*}
        suffix="rkloader-${model}".img
        suffixes+=("${suffix}")
        image=out/"${build_id}"-"${suffix}"
        temp_image="${image}".temp
        # Use cp as it could reflink if the fs supports it
        cp "${base_image}" "${temp_image}"
        dd if=src/rkloader/"${rkloader}" of="${temp_image}" conv=notrunc
        sfdisk "${temp_image}" <<< "${table}"
        case ${model} in
        5)
            mv "${temp_image}" "${image}"
            continue
        ;;
        5_sata)
            fdt='rk3588s-orangepi-5.dtb\n\tFDTOVERLAYS\t/dtbs/linux-aarch64-orangepi5/rockchip/overlay/rk3588-ssd-sata0.dtbo'
        ;;
        5b)
            fdt='rk3588s-orangepi-5b.dtb'
        ;;
        5_plus)
            fdt='rk3588-orangepi-5-plus.dtb'
        ;;
        esac
        sed 's|rk3588s-orangepi-5.dtb|'"${fdt}"'|' cache/extlinux.conf > cache/extlinux.conf.temp
        mcopy -oi cache/boot.img cache/extlinux.conf.temp ::extlinux/extlinux.conf
        sync
        dd if=cache/boot.img of="${temp_image}" bs=1M seek=4 conv=notrunc
        mv "${temp_image}" "${image}"
    done
}

release() {
    pids_gzip=()
    rm -rf out/latest
    mkdir out/latest
    for suffix in "${suffixes[@]}"; do
        gzip -9 out/"${build_id}-${suffix}" &
        pids_gzip+=($!)
        ln -s ../"${build_id}-${suffix}".gz out/latest/
    done
    echo "Waiting for gzip processes to end..."
    wait ${pids_gzip[@]}
}

get_subid() { #1 name #2 uid, #3 type
    local subid=$(grep '^'"$1"':[0-9]\+:[0-9]\+$' /etc/"$3" | tail -1)
    if [[ -z "${subid}" ]]; then
        subid=$(grep '^'"$2"':[0-9]\+:[0-9]\+$' /etc/"$3" | tail -1)
    fi
    if [[ -z "${subid}" ]]; then
        echo "ERROR: failed to get $3 for current user"
        exit 1
    fi
    echo "${subid}"
}

spawn_and_wait() {
    local username=$(id --user --name)
    if [[ -z "${username}" ]]; then
        echo 'ERROR: Failed to get user name of current user'
        exit 1
    fi
    local subuid=$(get_subid "${username}" "${uid}" subuid)
    local subgid=$(get_subid "${username}" "${uid}" subgid)
    local uid_range="${subuid##*:}"
    # We need to map the user to 0:0, and others to 1:65535
    if [[ "${uid_range}" -lt 65535 ]]; then
        echo 'ERROR: subuid range too short'
        exit 1
    fi
    local gid_range="${subgid##*:}"
    if [[ "${gid_range}" -lt 65535 ]]; then
        echo 'ERROR: subgid range too short'
        exit 1
    fi
    local uid_start="${subuid#*:}"
    uid_start="${uid_start%:*}"
    local gid_start="${subgid#*:}"
    gid_start="${gid_start%:*}"
    
    local args=()
    local arg=
    for arg in "${install_pkgs_bootstrap[@]}"; do
        args+=(--install-bootstrap "$arg")
    done
    for arg in "${install_pkgs_normal[@]}"; do
        args+=(--install "$arg")
    done
    for arg in "${install_pkgs_kernel[@]}"; do
        args+=(--install-kernel "$arg")
    done
    for arg in "${rkloaders[@]}"; do
        args+=(--rkloader "$arg")
    done
    # Note: the options --map-users and --map-groups were added to unshare.1 in 
    # util-linux 2.38, which was released on Mar 28, 2022. But the main distro
    # I aim, Ubuntu 22.04, which is what Github Actions use, packs an older
    # util-linux 2.37, which does not have those arguments. So we have to work
    # around this by calling newuidmap and newgidmap directly.
    unshare --user --pid --mount --fork \
        /bin/bash -e "${arg0}" --role child --uuid-root "${uuid_root}" --uuid-boot "${uuid_boot}" --build-id "${build_id}"  "${args[@]}" &
    child_pid="$!"
    newuidmap "${child_pid}" 0 "${uid}" 1 1 "${uid_start}" 65535
    newgidmap "${child_pid}" 0 "${gid}" 1 1 "${gid_start}" 65535
    wait "${child_pid}"
    child_pid=
}

prepare_host() {
    prepare_host_dirs
    get_rkloaders
    config_repos
    prepare_pacman_static
    prepare_pacman_configs
}

image_boot() {
    local image=cache/boot.img
    rm -f "${image}"
    truncate -s 100M "${image}"
    mkfs.vfat -n 'ALARMBOOT' -F 32 -i "${uuid_boot_mkfs}" "${image}"
    mcopy -osi "${image}" cache/root/boot/* ::
}

cleanup_boot() {
    rm -rf cache/root/boot/*
}

image_root() {
    local image=cache/root.img
    rm -f "${image}"
    truncate -s 1943M "${image}"
    mkfs.ext4 -L 'ALARMROOT' -m 0 -U "${uuid_root}" -d cache/root "${image}"
}

cleanup_cache() {
    rm -rf cache
}

work_parent() {
    check_identity_non_root
    trap "cleanup_parent" INT TERM EXIT
    prepare_host
    spawn_and_wait
    # The child should have prepared the following artifacts: cache/root.img cache/boot.img cache/extlinux.conf
    # And the child should have already finished out/*-root.tar
    image_disk
    image_rkloader
    release
    cleanup_cache
}

work_child() {
    sleep 1
    check_identity_map_root
    trap "cleanup_child" INT TERM EXIT
    mount_root
    bootstrap_root
    install_mkinitcpio
    install_pkgs
    setup_root
    setup_kernel
    setup_extlinux
    unhack_mkinitcpio
    cleanup_pkgs
    umount_root_sub
    archive_root
    image_boot
    cleanup_boot
    image_root
}

work_grandchild() {
    :
}

# Common main routine
install_pkgs_bootstrap=()
install_pkgs_normal=()
install_pkgs_kernel=()
build_id=''
uuid_root=''
uuid_boot=''
uuid_boot_mkfs=''
uuid_boot_specifier=''
rkloaders=()

arg0="$0"
argv=("$@")
argc=$#
role='parent'

i=0
while [[ $i -lt ${argc} ]]; do
    case "${argv[$i]}" in
        --install)
            i=$(( $i + 1 ))
            install_pkgs_normal+=("${argv[$i]}")
            ;;
        --install-bootstrap)
            i=$(( $i + 1 ))
            install_pkgs_bootstrap+=("${argv[$i]}")
            ;;
        --install-kernel)
            i=$(( $i + 1 ))
            install_pkgs_kernel+=("${argv[$i]}")
            ;;
        --role)
            i=$(( $i + 1 ))
            role="${argv[$i]}"
            ;;
        --uuid-root)
            i=$(( $i + 1 ))
            uuid_root="${argv[$i]}"
            ;;
        --uuid-boot)
            i=$(( $i + 1 ))
            uuid_boot="${argv[$i]}"
            ;;
        --build-id)
            i=$(( $i + 1 ))
            build_id="${argv[$i]}"
            ;;
        --rkloader)
            i=$(( $i + 1 ))
            rkloaders+=("${argv[$i]}")
            ;;
        --freeze-rkloader)
            freeze_rkloaders='yes'
            ;;
        --local-mirror)
            pkg_from_local_mirror='yes'
            ;;
        --help)
            help
            exit 0
            ;;
        *)
            echo "ERROR: Unknown arg '${argv[$i]}'"
            help
            exit 1
            ;;
    esac
    i=$(( $i + 1 ))
done

if [[ -z "${build_id}" ]]; then
    build_id=ArchLinuxARM-aarch64-OrangePi5-$(date +%Y%m%d_%H%M%S)
fi

if [[ "${#install_pkgs_bootstrap[@]}" == 0 ]]; then
    install_pkgs_bootstrap=(base archlinuxarm-keyring 7ji-keyring)
fi
    
if [[ "${#install_pkgs_normal[@]}" == 0 ]]; then
    install_pkgs_normal=(vim nano sudo openssh linux-firmware-orangepi usb2host)
fi

if [[ "${#install_pkgs_kernel[@]}" == 0 ]]; then
    install_pkgs_kernel=(linux-aarch64-orangepi5)
fi

if [[ -z "${uuid_root}" ]]; then
    uuid_root=$(uuidgen)
fi

if [[ -z "${uuid_boot}" ]]; then
    uuid_boot=$(uuidgen)
fi
uuid_boot_mkfs=${uuid_boot::8}
uuid_boot_mkfs=${uuid_boot_mkfs^^}
uuid_boot_specifier="${uuid_boot_mkfs::4}-${uuid_boot_mkfs:4}"

case "${role}" in
    parent) work_parent;;
    child) work_child;;
    grandchild) work_grandchild;;
    *)
        echo 'ERROR: Role invalid: '"${role}"
        exit 1
        ;;
esac