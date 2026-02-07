#!/bin/bash

# ===== GitHub Proxy =====
GH_PROXY="https://gh-proxy.com/"

current_time="$(date +%Y_%m_%d_%H_%M_%S)"
work_dir=".nodequality$current_time"

bench_os_url="${GH_PROXY}https://github.com/LloydAsp/NodeQuality/releases/download/v0.0.1/BenchOs.tar.gz"
raw_file_prefix="${GH_PROXY}https://raw.githubusercontent.com/LloydAsp/NodeQuality/refs/heads/main"

if uname -m | grep -Eq 'arm|aarch64'; then
    bench_os_url="${GH_PROXY}https://github.com/LloydAsp/NodeQuality/releases/download/v0.0.1/BenchOs-arm.tar.gz"
fi

header_info_filename=header_info.log
basic_info_filename=basic_info.log
yabs_json_filename=yabs.json
ip_quality_filename=ip_quality.log
ip_quality_json_filename=ip_quality.json
net_quality_filename=net_quality.log
net_quality_json_filename=net_quality.json
backroute_trace_filename=backroute_trace.log
backroute_trace_json_filename=backroute_trace.json
port_filename=port.log

function start_ascii(){
    echo -ne "\e[1;36m"
    cat <<- EOF

███╗   ██╗ ██████╗ ██████╗ ███████╗ ██████╗ ██╗   ██╗ █████╗ ██╗     ██╗████████╗██╗   ██╗
████╗  ██║██╔═══██╗██╔══██╗██╔════╝██╔═══██╗██║   ██║██╔══██╗██║     ██║╚══██╔══╝╚██╗ ██╔╝
██╔██╗ ██║██║   ██║██║  ██║█████╗  ██║   ██║██║   ██║███████║██║     ██║   ██║    ╚████╔╝
██║╚██╗██║██║   ██║██║  ██║██╔══╝  ██║▄▄ ██║██║   ██║██╔══██║██║     ██║   ██║     ╚██╔╝
██║ ╚████║╚██████╔╝██████╔╝███████╗╚██████╔╝╚██████╔╝██║  ██║███████╗██║   ██║      ██║
╚═╝  ╚═══╝ ╚═════╝ ╚═════╝ ╚══════╝ ╚══▀▀═╝  ╚═════╝ ╚═╝  ╚═╝╚══════╝╚═╝   ╚═╝      ╚═╝

Benchmark script for server, collects basic hardware information, IP quality and network quality

Author: Lloyd@nodeseek.com
Github: github.com/LloydAsp/NodeQuality
Command: bash <(curl -sL https://run.NodeQuality.com)

EOF
    echo -ne "\033[0m"
}

function _green_bold(){ echo -e "\033[1;32m$1\033[0m"; }
function _red(){ echo -e "\033[0;31m$1\033[0m"; }

function pre_init(){
    mkdir -p "$work_dir"
    cd "$work_dir" || exit 1
    work_dir="$(pwd)"
}

function clear_mount(){
    swapoff "$work_dir/swap" 2>/dev/null
    umount "$work_dir/BenchOs/proc/" 2>/dev/null
    umount "$work_dir/BenchOs/sys/" 2>/dev/null
    umount -R "$work_dir/BenchOs/dev/" 2>/dev/null
}

function pre_cleanup(){
    clear_mount
    [[ "$work_dir" == *"nodequality"* ]] && rm -rf "${work_dir:?}/"* || exit 1
}

function load_bench_os(){
    cd "$work_dir" || exit 1
    rm -rf BenchOs
    curl -L# -o BenchOs.tar.gz "$bench_os_url"
    tar -xzf BenchOs.tar.gz
    cd BenchOs || exit 1

    mount -t proc /proc proc/
    mount --bind /sys sys/
    mount --rbind /dev dev/
    mount --make-rslave dev

    cp /etc/resolv.conf etc/resolv.conf
}

function chroot_run(){
    chroot "$work_dir/BenchOs" /bin/bash -c "$*"
}

function load_part(){
    . <(curl -sL "$raw_file_prefix/part/swap.sh")
}

function load_3rd_program(){
    chroot_run wget "${GH_PROXY}https://github.com/nxtrace/NTrace-core/releases/download/v1.3.7/nexttrace_linux_amd64" -qO /usr/local/bin/nexttrace
    chroot_run chmod +x /usr/local/bin/nexttrace
}

function run_header(){
    chroot_run bash <(curl -sL "$raw_file_prefix/part/header.sh")
}

yabs_url="$raw_file_prefix/part/yabs.sh"
function run_yabs(){
    chroot_run bash <(curl -sL "$yabs_url") -s -- -5i -w /result/$yabs_json_filename
    chroot_run bash <(curl -sL "$raw_file_prefix/part/sysbench.sh")
}

function run_ip_quality(){
    chroot_run bash <(curl -Ls IP.Check.Place) -n -o /result/$ip_quality_json_filename
}

function run_net_quality(){
    chroot_run bash <(curl -Ls Net.Check.Place) -n -o /result/$net_quality_json_filename
}

function run_net_trace(){
    chroot_run bash <(curl -Ls Net.Check.Place) -R -n -S 123 -o /result/$backroute_trace_json_filename
}

uploadAPI="https://api.nodequality.com/api/v1/record"
function upload_result(){
    chroot_run zip -j - "/result/*" > "$work_dir/result.zip"
    base64 "$work_dir/result.zip" | curl -X POST --data-binary @- "$uploadAPI"
}

function post_cleanup(){
    clear_mount
    rm -rf "$work_dir"
    exit
}

function sig_cleanup(){
    trap '' INT TERM SIGHUP EXIT
    _red "Cleaning..."
    post_cleanup
}

function main(){
    trap 'sig_cleanup' INT TERM SIGHUP EXIT

    start_ascii
    pre_init
    pre_cleanup

    _green_bold "Load BenchOS"
    load_bench_os
    load_part
    load_3rd_program

    result_dir="$work_dir/BenchOs/result"
    mkdir -p "$result_dir"

    run_header > "$result_dir/$header_info_filename"
    run_yabs | tee "$result_dir/$basic_info_filename"
    run_ip_quality | tee "$result_dir/$ip_quality_filename"
    run_net_quality | tee "$result_dir/$net_quality_filename"
    run_net_trace | tee "$result_dir/$backroute_trace_filename"

    upload_result
    post_cleanup
}

main
