#!/usr/bin/env bash
# ============================================================================
# Repo: https://github.com/brucenguyen1102/Canon-LBP2900-CAPT-Toolkit
# Design by Bruce Nguyen from CCTVWIKI.COM va Claude Code Max
# ============================================================================
# CONG CU TONG HOP: Canon LBP2900 / LBP2900B tren Ubuntu/Mint
#   1) Go va cai lai LBP2900 (may nay cam truc tiep qua USB) - hoi chon 1 trong
#      2 loai driver (2 driver loai tru lan nhau, cai cai nay tu go cai kia):
#      a. Driver CUSTOM ValdikSS/captdriver (mac dinh, khuyen nghi - co
#         page-streaming, tranh treo khi in tai lieu nhieu hinh anh), da duoc
#         gia co them (xem captdriver-engine-hardening.patch: job ket thuc cho
#         engine may in that su ranh truoc khi thoat, cac vong lap cho trang
#         thai co gioi han thoi gian thay vi treo vo han, log chan doan chi
#         tiet hon) + tu dong va loi race condition CUPS backend + chia se qua
#         LAN + bat LogLevel debug vinh vien cho CUPS (de neu co su co sau nay
#         thi /var/log/cups/error_log da co san du log chi tiet de phan tich)
#      b. Driver CHINH HANG Canon v2.71 (tu goi linux-capt-drv-v271-uken.tar.gz
#         dat canh script, tu dong cai thu vien ho tro 32-bit can thiet, bat
#         daemon ccpd, khoi phuc module usblp ma driver custom da go)
#   2) Cai LBP2900 qua mang tu may khac (Linux) - ket noi toi may chu da chia se
#   3) Cai LBP2900 qua mang tu may khac (Windows) - hien huong dan (xem them
#      file huong-dan-ket-noi-may-in.html di kem)
#   4) Sua loi "may in khong phan hoi" (CAPT no reply) - tu dong reset USB
#   5) Va loi treo khi in tai lieu phuc tap (nhieu hinh anh) - danh cho may
#      da cai LBP2900 tu truoc, chi ap dung lai 2 ban va ma khong can cai lai
#      tu dau
#   6) Thoat
#
# Cach dung: sudo bash may-in-lbp2900.sh              (menu tuong tac)
#            sudo bash may-in-lbp2900.sh --yes 1       (chay thang muc 1, tu dong
#                                                        chon mac dinh cho moi cau hoi)
#            sudo bash may-in-lbp2900.sh --rollback-cups-backend
#            sudo bash may-in-lbp2900.sh --rollback-captdriver-filter
#                                                       (khoi phuc nhanh neu muc 5
#                                                        gay ra van de moi, xem
#                                                        phan "Nang cao" trong
#                                                        file huong dan HTML)
#
# CHAY OFFLINE (khong can GitHub): dat 2 file sau CUNG THU MUC voi script nay
# truoc khi chay - script se tu dung, khong tai mang cho 2 phan nay:
#   - captdriver-valdikss-val.tar.gz   (ma nguon captdriver ValdikSS)
#   - cups-1461-usb-backend-fix.patch  (patch va loi CUPS usb backend)
# (buoc "apt-get source cups" van can mang toi kho Ubuntu, khong lien quan GitHub)
# Neu chon cai driver Canon CHINH HANG o muc 1, can them file (bat buoc, vi
# driver Canon co ban quyen rieng nen khong tu tai ve duoc):
#   - linux-capt-drv-v271-uken.tar.gz  (CAPT Printer Driver for Linux v2.71)
# ============================================================================
set -uo pipefail

# Ep locale C cho TOAN BO script: tren may dat locale tieng Viet (vi_VN.UTF-8 -
# rat pho bien voi nguoi dung Viet Nam, chinh la doi tuong toolkit nay huong
# toi), lenh "automake" (Perl, dung trong buoc autoreconf khi build captdriver)
# bi SEGFAULT (signal 11) do loi xu ly locale - da xac minh thuc te: cung lenh
# do chay OK ngay khi ep LC_ALL=C. An toan de ep toan cuc vi moi thong bao cua
# script deu la chuoi ASCII/tieng Viet khong dau co dinh, khong phu thuoc locale.
export LC_ALL=C
export LANG=C

# Thu muc chua chinh file script nay - dung de tim cac file dong goi san
# (captdriver-valdikss-val.tar.gz, cups-1461-usb-backend-fix.patch) dat CANH
# script, de KHONG can tai tu GitHub moi lan chay (tien loi khi mang cham/bi
# chan, hoac muon cai offline). Neu khong thay file dong goi san, script tu
# dong tai ve tu GitHub nhu binh thuong.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd)"
[[ -z "$SCRIPT_DIR" ]] && SCRIPT_DIR="."

PRINTER_NAME="LBP2900"
BUILD_DIR="/usr/local/src/captdriver-lbp2900"
VENDOR_ID="04a9"
PRODUCT_ID="2676"
CAPTDRIVER_REPO="https://github.com/ValdikSS/captdriver.git"
CAPTDRIVER_BRANCH="val"
CAPTDRIVER_BUNDLE="${SCRIPT_DIR}/captdriver-valdikss-val.tar.gz"
# Goi driver Canon CHINH HANG v2.71 (CAPT Printer Driver for Linux), dat canh
# script. Chi can khi nguoi dung chon cai driver chinh hang o MUC 1 - driver
# nay co ban quyen Canon, khong tu dong tai ve duoc, phai lay tu trang Canon.
# --- Ban va "engine wedge job 5" (captd persistent daemon) ---------------
# Nguyen nhan goc (tim ra 2026-07-14): rastertocapt la CUPS *filter*, con
# CUPS usb backend MO VA DONG lai ket noi USB mieng moi job, nen tu job thu 5
# ke tu luc bat may la engine may in ket cung ("ReserveUnit failed 0x8c",
# phai tat bat lai may in). Driver Canon that (ca Windows lan Linux) khong bi
# vi chung giu MOT phien USB lien tuc qua tat ca cac job (Canon dung daemon
# ccpd). captd + capt-backend o day lam dung kien truc do, cong voi 3 file
# nguon captdriver da va lai giao thuc cho khop driver Canon Linux that.
# BAT BUOC phai co ca 4 phan, thieu bat ky phan nao la loi job 5 quay lai.
CAPTD_SRC_DIR="${SCRIPT_DIR}/captd-persistent-daemon"
CAPTD_SOCK="/run/captd/lbp2900.sock"
CAPTD_BIN="/usr/local/bin/captd"
CAPTD_SERVICE="/etc/systemd/system/captd.service"
# Cac file nguon captdriver da va (ghi de len file cung ten trong src/ truoc
# build). KHONG phu thuoc vao viec tarball dong san da duoc gia co hay chua:
# GitHub Action tu dong lam moi captdriver-valdikss-val.tar.gz tu upstream moi
# ngay, ghi de mat phan gia co (engine hardening) da tung nam trong tarball.
# Vi vay ca ban va chong treo job 5 LAN ban gia co deu duoc dua vao day, de
# ket qua build luon dung du tarball bi lam moi luc nao.
#   - prn_lbp2900.c, printer.h, capt-command.h, capt-command.c: ban va job 5
#   - capt-status.c, capt-status.h, generic-ops.c: ban gia co (engine hardening,
#     xem captdriver-engine-hardening.patch)
CAPTD_PATCHED_SRCS=(prn_lbp2900.c printer.h capt-command.h capt-command.c
                    capt-status.c capt-status.h generic-ops.c)
CANON_OFFICIAL_BUNDLE="${SCRIPT_DIR}/linux-capt-drv-v271-uken.tar.gz"
CANON_OFFICIAL_PPD="/usr/share/cups/model/CNCUPSLBP2900CAPTK.ppd"
CANON_OFFICIAL_URI="ccp://localhost:59687"
GIT_TIMEOUT_SECS=120
PPD_PATH=""
CANON_URI=""
CUPSD_CONF="/etc/cups/cupsd.conf"
DEFAULT_SERVER_IP="192.168.1.152"   # sua neu may chu co IP khac

# Va loi race condition CUPS backend (OpenPrinting/cups#1461)
CUPS_PATCH_WORKDIR="/usr/local/src/cups-usb-backend-fix"
CUPS_PATCH_URL="https://github.com/OpenPrinting/cups/commit/ca92bf7fcf18e6e055c63ff701934b5d74b5d80d.patch"
CUPS_PATCH_BUNDLE="${SCRIPT_DIR}/cups-1461-usb-backend-fix.patch"
CUPS_PATCH_SOURCES_FILE="/etc/apt/sources.list.d/ubuntu-noble-src.list"
MINT_REPO_FILE="/etc/apt/sources.list.d/official-package-repositories.list"
# Chuoi debug chi co trong ban da va (them boi patch ca92bf7...), dung de
# nhan biet backend dang chay da duoc va hay chua.
CUPS_PATCH_MARKER="wakeup pipe"

# -y/--yes/--non-interactive: tu dong chon mac dinh cho moi cau hoi.
# Tham so so (1-5) con lai: chay thang muc do roi thoat, bo qua menu.
# --official: o MUC 1, cai driver Canon chinh hang thay vi driver custom
# (bo qua cau hoi chon driver).
# --rollback-cups-backend / --rollback-captdriver-filter: khoi phuc nhanh
# (nang cao, khong hien trong menu) neu muc 5 gay van de moi.
ASSUME_YES=0
DIRECT_ACTION=""
DRIVER_OFFICIAL=0
ROLLBACK_CUPS_BACKEND=0
ROLLBACK_CAPTDRIVER_FILTER=0
for _arg in "$@"; do
    case "$_arg" in
        -y|--yes|--non-interactive) ASSUME_YES=1 ;;
        --official|--canon-official) DRIVER_OFFICIAL=1 ;;
        --rollback-cups-backend) ROLLBACK_CUPS_BACKEND=1 ;;
        --rollback-captdriver-filter) ROLLBACK_CAPTDRIVER_FILTER=1 ;;
        1|2|3|4|5) DIRECT_ACTION="$_arg" ;;
    esac
done

# ---------------------------------------------------------------------------
# Mau sac / logging
# ---------------------------------------------------------------------------
if [[ -t 1 ]]; then
    C_RED='\033[0;31m'; C_GREEN='\033[0;32m'; C_YELLOW='\033[1;33m'
    C_BLUE='\033[0;34m'; C_CYAN='\033[0;36m'; C_BOLD='\033[1m'; C_NC='\033[0m'
else
    C_RED=''; C_GREEN=''; C_YELLOW=''; C_BLUE=''; C_CYAN=''; C_BOLD=''; C_NC=''
fi

log_info()  { printf '%b\n' "${C_BLUE}[THONG TIN]${C_NC} $*"; }
log_ok()    { printf '%b\n' "${C_GREEN}[OK]${C_NC} $*"; }
log_warn()  { printf '%b\n' "${C_YELLOW}[CANH BAO]${C_NC} $*"; }
log_error() { printf '%b\n' "${C_RED}[LOI]${C_NC} $*" >&2; }
log_step()  { printf '\n%b\n' "${C_BOLD}${C_CYAN}==== $* ====${C_NC}"; }

log_manual() {
    printf '\n%b\n' "${C_YELLOW}${C_BOLD}------------------------------------------------------------${C_NC}"
    printf '%b\n'   "${C_YELLOW}${C_BOLD}  CAN THAO TAC THU CONG TU BAN${C_NC}"
    printf '%b\n'   "${C_YELLOW}${C_BOLD}------------------------------------------------------------${C_NC}"
    printf '%b\n\n' "${C_YELLOW}$1${C_NC}"
}

die() { log_error "$*"; exit 1; }

# ---------------------------------------------------------------------------
# Tro giup tuong tac
# ---------------------------------------------------------------------------
ask_yes_no() {
    local prompt="$1" default="${2:-y}" suffix ans
    if [[ "$default" == "n" ]]; then suffix="[y/N]"; else suffix="[Y/n]"; fi
    if [[ "$ASSUME_YES" -eq 1 ]]; then
        log_info "$prompt $suffix -> tu dong chon '$default' (che do --yes)"
        ans="$default"
    else
        read -rp "$prompt $suffix: " ans || true
        ans="${ans:-$default}"
    fi
    [[ "$ans" =~ ^[Yy]$ ]]
}

ask_value() {
    local prompt="$1" default="$2" ans
    if [[ "$ASSUME_YES" -eq 1 ]]; then
        printf '%s\n' "$default"
        return 0
    fi
    read -rp "$prompt [$default]: " ans || true
    printf '%s\n' "${ans:-$default}"
}

# Thu lai N lan mot ham "probe"; neu van that bai thi hien huong dan thu cong
# roi doi Enter va thu lai toan bo vong lap. Go 's' de bo qua, 'q' de huy CHI
# hanh dong hien tai (khong thoat ca cong cu, vi day la menu nhieu lua chon).
# Tra ve: 0 = thanh cong, 1 = da huy, 2 = nguoi dung chon bo qua.
retry_with_manual_fallback() {
    local probe_fn="$1" manual_fn="$2" desc="$3"
    local max_attempts="${4:-3}" delay="${5:-2}"
    local attempt choice

    while true; do
        attempt=1
        while (( attempt <= max_attempts )); do
            if "$probe_fn"; then
                return 0
            fi
            log_warn "Chua phat hien duoc: $desc (lan thu $attempt/$max_attempts)"
            sleep "$delay"
            ((attempt++))
        done

        "$manual_fn"

        if [[ "$ASSUME_YES" -eq 1 ]]; then
            log_error "Che do --yes: khong the tu dong xac nhan '$desc' sau nhieu lan thu (khong co nguoi de thao tac thu cong)."
            return 1
        fi

        read -rp "Nhan Enter de THU LAI, go 's' de BO QUA buoc nay, hoac 'q' de HUY hanh dong nay: " choice || choice='q'
        case "$choice" in
            [qQ])
                log_error "Da huy hanh dong theo yeu cau nguoi dung."
                return 1
                ;;
            [sS])
                log_warn "Da bo qua buoc: $desc"
                return 2
                ;;
            *)
                : # thu lai vong lap
                ;;
        esac
    done
}

safe_rm_glob() {
    local pattern files saved
    saved=$(shopt -p nullglob)
    shopt -s nullglob
    files=()
    for pattern in "$@"; do
        # shellcheck disable=SC2206
        files+=( $pattern )
    done
    eval "$saved"
    if (( ${#files[@]} > 0 )); then
        rm -rf -- "${files[@]}"
    fi
}

run_step() {
    local desc="$1"; shift
    log_info "$desc"
    if ! "$@"; then
        log_error "Buoc that bai: $desc"
        return 1
    fi
    return 0
}

require_root() {
    if [[ "${EUID}" -ne 0 ]]; then
        echo "Cong cu nay can quyen root de cai dat/cau hinh he thong."
        echo "Dang tu dong chay lai bang sudo..."
        exec sudo -E bash "$0" "$@"
        log_error "Khong the chay lai bang sudo. Vui long chay lai voi quyen root."
        exit 1
    fi
}

# Kiem tra file la ELF executable hop le, khong rong.
verify_elf() {
    local f="$1"
    [[ -s "$f" ]] || { log_error "File rong hoac khong ton tai: $f"; return 1; }
    command -v file >/dev/null 2>&1 || { log_error "Thieu lenh 'file', khong the kiem tra an toan"; return 1; }
    file "$f" | grep -q "ELF" || { log_error "File khong phai ELF: $f"; return 1; }
    file "$f" | grep -Eq "executable|pie executable|shared object" || { log_error "ELF nhung khong phai dang executable: $f"; return 1; }
    return 0
}

# Kiem tra chuoi danh dau co trong binary hay khong. KHONG duoc viet la
# "strings f | grep -qi X": grep -q thoat ngay khi tim thay match dau tien,
# gui SIGPIPE cho strings dang ghi do, khien strings chet voi exit code khac
# 0 - va duoi "set -o pipefail" ca pipeline bi bao THAT BAI dung luc grep vua
# TIM THAY match (da gap loi nay thuc te khi phat trien cong cu nay). Chup
# toan bo output cua strings vao bien truoc, roi moi grep tren bien do.
binary_has_string() {
    local f="$1" pattern="$2" out
    [[ -f "$f" ]] || return 1
    command -v strings >/dev/null 2>&1 || return 1
    out="$(strings "$f" 2>/dev/null)"
    grep -qi "$pattern" <<< "$out"
}

# Tinh dia chi mang (network) tu IP + prefix, vd 192.168.1.152 24 -> 192.168.1.0/24
cidr_network() {
    local ip="$1" prefix="$2"
    local IFS=. o1 o2 o3 o4
    read -r o1 o2 o3 o4 <<< "$ip"
    local ip_int=$(( (o1<<24) + (o2<<16) + (o3<<8) + o4 ))
    local mask
    if (( prefix == 0 )); then mask=0; else mask=$(( (0xFFFFFFFF << (32 - prefix)) & 0xFFFFFFFF )); fi
    local net_int=$(( ip_int & mask ))
    printf '%d.%d.%d.%d/%d' $(( (net_int>>24)&255 )) $(( (net_int>>16)&255 )) $(( (net_int>>8)&255 )) $(( net_int&255 )) "$prefix"
}

detect_lan() {
    local iface ip_cidr ip_addr prefix
    iface=$(ip -4 route show default 2>/dev/null | awk '{print $5; exit}')
    if [[ -z "$iface" ]]; then
        log_error "Khong tim thay giao dien mang mac dinh (default route)."
        return 1
    fi
    ip_cidr=$(ip -4 -o addr show dev "$iface" scope global 2>/dev/null | awk '{print $4; exit}')
    if [[ -z "$ip_cidr" ]]; then
        log_error "Khong tim thay dia chi IPv4 tren giao dien $iface."
        return 1
    fi
    ip_addr="${ip_cidr%/*}"
    prefix="${ip_cidr#*/}"
    LAN_IFACE="$iface"
    LAN_HOST_IP="$ip_addr"
    LAN_CIDR="$(cidr_network "$ip_addr" "$prefix")"
    return 0
}

# Kiem tra xem hang doi co dang bao loi giao tiep CAPT/USB hay khong
# (vd: "CAPT: no reply from printer", "CAPT: ReserveUnit failed" - may in
# bi ket phien giao tiep).
printer_has_capt_error() {
    local printer="$1"
    lpstat -p "$printer" -l 2>/dev/null | grep -qiE "CAPT:|no reply from printer|backend usb returned status"
}

# Reset "mem" cong USB cua may in bang phan mem (deauthorize/reauthorize qua
# sysfs) - khong can rut day/tat nguon vat ly. Chi giai quyet duoc phia
# Linux/USB-host; neu chinh dong dieu khien ben trong may in bi treo thi van
# can tat/bat nguon that (xem manual_capt_stuck).
recover_capt_usb_session() {
    log_step "Tu dong reset phien USB cho may in (khac phuc loi giao tiep CAPT)"
    local devpath="" d dir
    for d in /sys/bus/usb/devices/*/idVendor; do
        dir=$(dirname "$d")
        if [[ "$(cat "$d" 2>/dev/null)" == "$VENDOR_ID" && "$(cat "$dir/idProduct" 2>/dev/null)" == "$PRODUCT_ID" ]]; then
            devpath="$dir"
            break
        fi
    done
    if [[ -z "$devpath" ]]; then
        log_warn "Khong tim thay thiet bi USB ${VENDOR_ID}:${PRODUCT_ID} de reset (co the da bi rut ra)."
        return 1
    fi
    log_info "Dang reset cong USB tai ${devpath} ..."
    echo 0 > "${devpath}/authorized" 2>/dev/null
    sleep 3
    echo 1 > "${devpath}/authorized" 2>/dev/null
    sleep 3
    if lsusb 2>/dev/null | grep -qiE "${VENDOR_ID}:${PRODUCT_ID}"; then
        log_ok "May in da tai xuat hien tren USB sau khi reset phan mem."
    else
        log_warn "May in khong thay xuat hien lai tren USB sau khi reset phan mem."
    fi
    systemctl restart cups >/dev/null 2>&1 || true
    sleep 1
    return 0
}

manual_capt_stuck() {
    log_manual "Phan mem da thu reset nhung may in van bao loi giao tiep.
Day la loi thuong gap voi may in CAPT doi cu khi bo dieu khien ben trong may
in bi treo (khong phai loi cai dat) - can thao tac vat ly that su:
  1. TAT NGUON may in, doi khoang 10 giay, roi BAT LAI.
  2. Neu van khong duoc, RUT day cap USB ra khoi may tinh, doi 5 giay, CAM LAI.
  3. Sau do chay lai 'In thu' hoac chon muc sua loi trong menu de kiem tra lai."
}

# Doi CHINH XAC mot job-id cu the roi khoi hang doi (in xong/loi/bi huy), toi
# da max_wait giay. Theo doi theo job-id (khong chi trang thai chung cua may
# in) vi may in co the dang xu ly job KHAC (tu may Linux/Windows khac gui
# cung luc) - kiem tra chung chung se bao nham ket qua cua job nguoi khac.
# Tra ve: 0 = job da roi khoi hang doi va khong co loi CAPT, 1 = van con loi
# CAPT trong luc job nay dang cho (job co the van dang bi ket).
wait_for_job_settle() {
    local job_id="$1" printer="$2" max_wait="${3:-60}" interval="${4:-5}" waited=0
    # Doi mot chut truoc lan kiem tra dau tien: ngay sau khi nop job, CUPS co
    # the chua kip dua job vao hang doi hien thi, kiem tra qua som se bao
    # "xong" gia (job chua kip xuat hien da tuong nham la da xong).
    sleep 2
    while (( waited < max_wait )); do
        if printer_has_capt_error "$printer"; then
            return 1
        fi
        if ! lpstat -o "$printer" 2>/dev/null | grep -q "^${job_id} "; then
            return 0
        fi
        sleep "$interval"
        (( waited += interval ))
    done
    printer_has_capt_error "$printer" && return 1
    return 0
}

# In thu tu dong (khong hoi), dung chung cho muc 1, 2 va 5. Tu phat hien va
# tu phuc hoi neu may in dang/bi ket phien giao tiep CAPT.
send_test_print() {
    local printer="$1"
    log_step "In thu tu dong"

    if printer_has_capt_error "$printer"; then
        log_warn "May in dang o trang thai loi giao tiep tu truoc. Dang tu dong reset USB truoc khi in..."
        cancel -a "$printer" >/dev/null 2>&1 || true
        recover_capt_usb_session
    fi

    local testfile=""
    local candidate
    for candidate in /usr/share/cups/data/testprint /usr/share/cups/data/default-testpage.pdf; do
        if [[ -f "$candidate" ]]; then testfile="$candidate"; break; fi
    done
    local is_tmp=0
    if [[ -z "$testfile" ]]; then
        testfile=$(mktemp --suffix=.txt)
        is_tmp=1
        printf 'CANON LBP2900 - TRANG IN THU\nNeu ban doc duoc dong nay, may in da hoat dong!\n' > "$testfile"
    fi

    local job_id
    job_id=$(lp -d "$printer" "$testfile" 2>/dev/null | grep -oE "${printer}-[0-9]+")

    if [[ -z "$job_id" ]]; then
        log_warn "Gui lenh in thu that bai (khong lay duoc job id)."
    else
        log_ok "Da gui job in thu '${job_id}'. Dang doi ket qua (toi da 60s)..."
        if ! wait_for_job_settle "$job_id" "$printer" 60 5; then
            log_warn "May in bao loi giao tiep khi xu ly job '${job_id}'. Dang tu dong reset USB va thu lai mot lan nua..."
            cancel "$job_id" >/dev/null 2>&1 || true
            recover_capt_usb_session
            job_id=$(lp -d "$printer" "$testfile" 2>/dev/null | grep -oE "${printer}-[0-9]+")
            if [[ -z "$job_id" ]]; then
                log_error "Khong gui lai duoc job in thu sau khi reset."
            else
                log_info "Da gui lai job '${job_id}'. Dang doi ket qua sau khi reset (toi da 60s)..."
                if ! wait_for_job_settle "$job_id" "$printer" 60 5; then
                    log_error "Van con loi sau khi tu dong reset bang phan mem."
                    manual_capt_stuck
                else
                    log_ok "Da TU DONG PHUC HOI thanh cong sau khi reset USB bang phan mem!"
                fi
            fi
        else
            log_ok "Job in thu '${job_id}' da hoan tat, khong con loi."
        fi
    fi

    (( is_tmp == 1 )) && rm -f "$testfile"
    lpstat -p "$printer" -l 2>&1 || true
    log_info "Neu khong in duoc, kiem tra log loi CUPS: sudo tail -n 50 /var/log/cups/error_log"
}

# ===========================================================================
# MUC 4: TU DONG KHAC PHUC "MAY IN KHONG PHAN HOI"
# ===========================================================================

action_fix_capt_stuck() {
    log_step "=== MUC 4: SUA LOI 'MAY IN KHONG PHAN HOI' ==="
    log_info "Trang thai hien tai:"
    lpstat -p "$PRINTER_NAME" -l 2>&1 || true
    cancel -a "$PRINTER_NAME" >/dev/null 2>&1 || true
    send_test_print "$PRINTER_NAME"
}

# ===========================================================================
# MUC 1 - phan A: DON DEP TOAN BO DAU VET CAI DAT CU (local, USB)
# ===========================================================================

purge_if_installed() {
    local pkg="$1"
    if dpkg -s "$pkg" >/dev/null 2>&1; then
        log_info "Dang go bo goi: $pkg"
        dpkg --purge "$pkg" >/dev/null 2>&1 || apt-get purge -y "$pkg" >/dev/null 2>&1 || \
            log_warn "Khong the go hoan toan $pkg (co the khong sao)."
    fi
}

cleanup_ccpd() {
    log_step "Don dep driver doc quyen Canon (ccpd / cndrvcups)"

    systemctl stop ccpd >/dev/null 2>&1 || true
    service ccpd stop >/dev/null 2>&1 || true
    killall ccpd captstatusui >/dev/null 2>&1 || true

    if [[ -x /usr/sbin/ccpdadmin ]]; then
        while read -r pname; do
            [[ -z "$pname" ]] && continue
            /usr/sbin/ccpdadmin -x "$pname" >/dev/null 2>&1 || true
        done < <(/usr/sbin/ccpdadmin 2>/dev/null | awk 'NF{print $1}')
    fi

    if [[ -f /etc/init.d/ccpd ]]; then
        update-rc.d -f ccpd remove >/dev/null 2>&1 || true
        rm -f /etc/init.d/ccpd
    fi
    rm -f /etc/init/ccpd-start.conf
    safe_rm_glob '/etc/rc[0-6].d/*ccpd*'

    rm -rf /var/ccpd /var/captmon /usr/share/ccpd
    rm -f /etc/ccpd.conf
    safe_rm_glob '/usr/local/lib/libuictlcapt*' '/usr/local/lib64/libuictlcapt*' '/usr/local/lib*/libuictlcapt*'
    rm -f /usr/bin/autoshutdowntool

    local homedir f
    for homedir in /root /home/*; do
        [[ -d "$homedir/Desktop" ]] || continue
        rm -f "$homedir/Desktop/captstatusui.desktop"
        for f in "$homedir"/Desktop/*.desktop; do
            [[ -f "$f" ]] || continue
            grep -q 'captstatusui -P' "$f" 2>/dev/null && rm -f -- "$f"
        done
    done

    if [[ -e /etc/apparmor.d/force-complain/usr.sbin.cupsd ]]; then
        rm -f /etc/apparmor.d/force-complain/usr.sbin.cupsd
        apparmor_parser -r /etc/apparmor.d/usr.sbin.cupsd >/dev/null 2>&1 || true
    fi

    purge_if_installed cndrvcups-capt
    purge_if_installed cndrvcups-common

    log_ok "Da don xong driver doc quyen Canon."
}

cleanup_cups_queues() {
    log_step "Don hang doi in Canon/LBP cu trong CUPS"
    local q
    while read -r q; do
        [[ -z "$q" ]] && continue
        log_info "Xoa hang doi CUPS: $q"
        cancel -a "$q" >/dev/null 2>&1 || true
        lpadmin -x "$q" >/dev/null 2>&1 || true
    done < <(lpstat -p 2>/dev/null | awk '/^printer/{print $2}' | grep -iE 'lbp|canon' 2>/dev/null)
    log_ok "Da kiem tra xong hang doi CUPS."
}

cleanup_captdriver_leftovers() {
    log_step "Don dau vet captdriver tu cac lan cai dat truoc"
    local serverbin filterdir
    serverbin=$(cups-config --serverbin 2>/dev/null || true)
    [[ -z "$serverbin" ]] && serverbin="/usr/lib/cups"
    filterdir="$serverbin/filter"

    rm -f "${filterdir}/rastertocapt"
    rm -f /usr/local/bin/rastertocapt

    safe_rm_glob '/usr/share/cups/model/CanonLBP*.ppd' '/usr/share/cups/model/CNCUPS*CAPT*.ppd'
    safe_rm_glob '/tmp/captdriver*' '/root/captdriver*' '/home/*/captdriver*'

    # QUAN TRONG: -mindepth 1 - neu khong, khi ten cua chinh $BUILD_DIR khop
    # dieu kien xoa thi lenh se tu xoa CHINH THU MUC DANG DUNG, gay loi kho
    # hieu o cac buoc sau (da tung gap loi nay khi phat trien cong cu).
    if [[ -d "$BUILD_DIR" && ! -d "$BUILD_DIR/.git" ]]; then
        rm -rf "$BUILD_DIR"
    fi
    log_ok "Da don xong dau vet captdriver cu."
}

cleanup_udev() {
    log_step "Don udev rules cu lien quan Canon/CAPT"
    rm -f /etc/udev/rules.d/85-canon-capt.rules
    safe_rm_glob '/etc/udev/rules.d/*[Cc]anon*.rules' '/etc/udev/rules.d/*capt*.rules' '/etc/udev/rules.d/*CAPT*.rules'
    udevadm control --reload-rules >/dev/null 2>&1 || true
    udevadm trigger >/dev/null 2>&1 || true
    log_ok "Da don xong udev rules cu."
}

report_i386_packages() {
    log_step "Kiem tra thu vien 32-bit (i386) lien quan (chi bao cao, KHONG tu xoa)"
    local pkgs=(libatk1.0-0:i386 libcairo2:i386 libgtk2.0-0:i386 libpango1.0-0:i386 \
                libpango-1.0-0:i386 libstdc++6:i386 libpopt0:i386 libxml2:i386 \
                libc6:i386 libtiff5:i386 libjpeg62:i386)
    local found=() p
    for p in "${pkgs[@]}"; do
        if dpkg -l "$p" 2>/dev/null | grep -q '^ii'; then
            found+=("$p")
        fi
    done
    if (( ${#found[@]} > 0 )); then
        log_warn "Phat hien cac goi i386 sau (khong tu dong go vi phan mem khac co the can dung):"
        printf '   - %s\n' "${found[@]}"
    else
        log_info "Khong phat hien goi thu vien i386 lien quan den driver Canon cu."
    fi
}

fix_ipp_usb_and_usblp() {
    log_step "Khac phuc xung dot ipp-usb / usblp voi may in USB"

    systemctl stop ipp-usb >/dev/null 2>&1 || true
    if dpkg -s ipp-usb >/dev/null 2>&1; then
        systemctl disable ipp-usb >/dev/null 2>&1 || true
        systemctl mask ipp-usb >/dev/null 2>&1 || true
        log_info "Da dung va vo hieu hoa dich vu ipp-usb (khong go cai dat goi, de khong anh huong toi may in USB khac neu co)."
    fi

    local lpnode
    for lpnode in /dev/usb/lp*; do
        [[ -e "$lpnode" ]] || continue
        fuser -k "$lpnode" >/dev/null 2>&1 || true
    done
    modprobe -r usblp >/dev/null 2>&1 || rmmod usblp >/dev/null 2>&1 || true

    log_warn "Canh bao: blacklist module usblp se anh huong TAT CA may in USB dung driver usblp tren may tinh nay (khong chi rieng Canon LBP2900), ke ca sau khi khoi dong lai."
    if ask_yes_no "Ban co muon blacklist usblp vinh vien de tranh xung dot voi captdriver?" "y"; then
        local blacklist_file="/etc/modprobe.d/blacklist-usblp.conf"
        local blacklist_line="blacklist usblp"
        if [[ ! -f "$blacklist_file" ]] || ! grep -qxF "$blacklist_line" "$blacklist_file" 2>/dev/null; then
            echo "$blacklist_line" > "$blacklist_file"
            log_ok "Da ghi $blacklist_file"
        else
            log_info "$blacklist_file da dung, bo qua."
        fi
    else
        log_warn "Da bo qua blacklist usblp. Neu may in LBP2900 khong hoat dong do usblp chiem thiet bi, hay chay lai muc nay va chon Co."
    fi

    local udev_rule_file="/etc/udev/rules.d/99-canon-lbp2900.rules"
    local udev_rule_line="SUBSYSTEM==\"usb\", ATTR{idVendor}==\"${VENDOR_ID}\", ATTR{idProduct}==\"${PRODUCT_ID}\", MODE=\"0664\", GROUP=\"lp\""
    if [[ ! -f "$udev_rule_file" ]] || ! grep -qxF "$udev_rule_line" "$udev_rule_file" 2>/dev/null; then
        echo "$udev_rule_line" > "$udev_rule_file"
        log_ok "Da ghi $udev_rule_file"
    else
        log_info "$udev_rule_file da dung, bo qua."
    fi

    udevadm control --reload-rules >/dev/null 2>&1 || true
    udevadm trigger >/dev/null 2>&1 || true
    systemctl restart cups >/dev/null 2>&1 || true

    log_ok "Da xu ly xong xung dot ipp-usb / usblp."
    log_warn "Luu y: neu usblp da giu thiet bi tu truoc, ban se can RUT/CAM LAI cap USB (huong dan se hien o buoc do tim may in)."
}

install_build_deps() {
    log_step "Cai dat goi phu thuoc de build captdriver"
    apt-get update -y || log_warn "apt-get update gap loi, van tiep tuc thu cai dat..."
    # libusb-1.0-0-dev + pkg-config + autoconf/libtool: can de build captd
    # (daemon giu phien USB lien tuc - xem build_and_install_captd).
    if ! apt-get install -y build-essential automake autoconf libtool pkg-config \
            libusb-1.0-0-dev libcups2-dev cups-ppdc cups cups-client usbutils git; then
        log_error "Khong the cai dat goi phu thuoc build. Kiem tra ket noi mang / nguon apt."
        return 1
    fi
    return 0
}

# Ghi de 3 file nguon captdriver da va giao thuc (nam trong captd-persistent-
# daemon/ canh script) len file cung ten trong <BUILD_DIR>/src/. Cac sua doi:
#   - SetJobInfo2(flag=CONT) gui LAP LAI ~500ms suot ca qua trinh in (truoc
#     day chi gui 1 lan/job) - dung nhip driver Canon Linux that.
#   - Gui GetExtendedStatus (0xA0A8) HAI LAN ngay truoc MOI ReserveUnit
#     (truoc day dung GetBasicStatus 0xE0A0 - khong giong driver that).
#   - Sua vai byte payload SetJobInfo2/IC_BEGIN_PAGE (2 bit co che do,
#     truong TonerDensity, co ket thuc job dung 3 chu khong phai 6).
overlay_captd_patched_sources() {
    log_step "Ghi de ma nguon captdriver da va (chong ket cung engine o job 5)"

    if [[ ! -d "$CAPTD_SRC_DIR" ]]; then
        log_error "Khong tim thay thu muc ma nguon da va: $CAPTD_SRC_DIR"
        log_error "Thu muc nay phai nam CANH script (cung cho voi may-in-lbp2900.sh)."
        return 1
    fi

    local f
    for f in "${CAPTD_PATCHED_SRCS[@]}"; do
        if [[ ! -f "${CAPTD_SRC_DIR}/${f}" ]]; then
            log_error "Thieu file ma nguon da va: ${CAPTD_SRC_DIR}/${f}"
            return 1
        fi
        if [[ ! -f "${BUILD_DIR}/src/${f}" ]]; then
            log_error "Ma nguon captdriver khong co file ${BUILD_DIR}/src/${f} (goi nguon sai phien ban?)"
            return 1
        fi
        if ! cp -f "${CAPTD_SRC_DIR}/${f}" "${BUILD_DIR}/src/${f}"; then
            log_error "Khong ghi de duoc ${BUILD_DIR}/src/${f}"
            return 1
        fi
        log_info "Da ghi de src/${f}"
    done

    log_ok "Da ap dung ${#CAPTD_PATCHED_SRCS[@]} file nguon da va truoc khi build."
    return 0
}

# Build + cai dat captd (daemon giu MOT phien USB lien tuc) va capt-backend
# (CUPS backend mong noi toi daemon qua Unix socket, THAY THE backend usb://
# chuan cua CUPS). Day la phan quan trong nhat cua ban va: chi sua ma nguon
# captdriver thoi la KHONG DU - da thu nghiem thuc te va van ket cung o job 5.
build_and_install_captd() {
    log_step "Build va cai dat captd (daemon giu phien USB lien tuc)"

    local src_captd="${CAPTD_SRC_DIR}/captd.c"
    local src_backend="${CAPTD_SRC_DIR}/capt-backend.c"
    if [[ ! -f "$src_captd" || ! -f "$src_backend" ]]; then
        log_error "Thieu captd.c / capt-backend.c trong $CAPTD_SRC_DIR"
        return 1
    fi

    local tmpd
    tmpd="$(mktemp -d)" || { log_error "Khong tao duoc thu muc tam."; return 1; }

    local usb_cflags usb_libs cups_libs
    usb_cflags="$(pkg-config --cflags libusb-1.0 2>/dev/null || true)"
    usb_libs="$(pkg-config --libs libusb-1.0 2>/dev/null || echo -lusb-1.0)"
    cups_libs="$(pkg-config --libs cups 2>/dev/null || echo -lcups)"

    # shellcheck disable=SC2086
    if ! gcc -O2 -o "${tmpd}/captd" "$src_captd" $usb_cflags $usb_libs -lpthread; then
        log_error "Bien dich captd that bai (thieu libusb-1.0-0-dev?)."
        rm -rf "$tmpd"; return 1
    fi
    # shellcheck disable=SC2086
    if ! gcc -O2 -o "${tmpd}/capt-backend" "$src_backend" $cups_libs; then
        log_error "Bien dich capt-backend that bai (thieu libcups2-dev?)."
        rm -rf "$tmpd"; return 1
    fi
    verify_elf "${tmpd}/captd" || { log_error "captd build ra khong hop le."; rm -rf "$tmpd"; return 1; }
    verify_elf "${tmpd}/capt-backend" || { log_error "capt-backend build ra khong hop le."; rm -rf "$tmpd"; return 1; }

    local serverbin backenddir
    serverbin=$(cups-config --serverbin 2>/dev/null || true)
    [[ -z "$serverbin" ]] && serverbin="/usr/lib/cups"
    backenddir="${serverbin}/backend"
    mkdir -p "$backenddir" "$(dirname "$CAPTD_BIN")"

    install -o root -g root -m 0755 "${tmpd}/captd" "$CAPTD_BIN" || {
        log_error "Cai dat $CAPTD_BIN that bai."; rm -rf "$tmpd"; return 1; }
    # CUPS BAT BUOC backend phai thuoc root va mode 0700 (neu khong CUPS se
    # tu choi chay backend do va job "thanh cong" nhung khong co gi in ra).
    install -o root -g root -m 0700 "${tmpd}/capt-backend" "${backenddir}/capt" || {
        log_error "Cai dat backend capt that bai."; rm -rf "$tmpd"; return 1; }
    rm -rf "$tmpd"
    log_ok "Da cai $CAPTD_BIN va ${backenddir}/capt"

    cat > "$CAPTD_SERVICE" <<UNIT
[Unit]
Description=Canon LBP2900 CAPT persistent USB session daemon
Documentation=https://github.com/brucenguyen1102/Canon-LBP2900-CAPT-Toolkit
After=network.target
Before=cups.service

[Service]
Type=simple
RuntimeDirectory=captd
ExecStart=${CAPTD_BIN} ${CAPTD_SOCK}
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
UNIT

    systemctl daemon-reload >/dev/null 2>&1 || true
    systemctl enable captd >/dev/null 2>&1 || log_warn "Khong enable duoc captd.service."
    systemctl restart captd >/dev/null 2>&1 || { log_error "Khong khoi dong duoc captd.service."; return 1; }

    local i
    for i in $(seq 1 15); do
        [[ -S "$CAPTD_SOCK" ]] && break
        sleep 1
    done
    if [[ ! -S "$CAPTD_SOCK" ]]; then
        log_error "captd khong tao duoc socket $CAPTD_SOCK sau 15 giay."
        log_error "Xem log: journalctl -u captd -n 30"
        return 1
    fi
    if ! systemctl is-active --quiet captd; then
        log_error "captd.service khong chay. Xem: journalctl -u captd -n 30"
        return 1
    fi

    CANON_URI="capt:${CAPTD_SOCK}"
    log_ok "captd dang chay, socket: ${CAPTD_SOCK}"
    log_ok "URI may in se dung: ${CANON_URI}"
    return 0
}

# Go captd (dung khi chuyen sang driver Canon chinh hang - hai kien truc
# khong the cung giu thiet bi USB).
remove_captd() {
    if systemctl list-unit-files 2>/dev/null | grep -q '^captd\.service'; then
        log_info "Dung va go captd.service (driver chinh hang dung ccpd thay the)."
        systemctl disable --now captd >/dev/null 2>&1 || true
    fi
    rm -f "$CAPTD_SERVICE"
    systemctl daemon-reload >/dev/null 2>&1 || true
    rm -f "$CAPTD_BIN"
    local serverbin
    serverbin=$(cups-config --serverbin 2>/dev/null || echo /usr/lib/cups)
    rm -f "${serverbin}/backend/capt"
}

# Build + cai dat captdriver (ban ValdikSS/captdriver, nhanh "val", co
# page-streaming de tranh treo may in khi in tai lieu nhieu hinh anh - da
# kiem chung thuc te tren LBP2900). Backup filter dang chay (neu co) truoc
# khi ghi de, xac minh ELF hop le truoc va sau khi cai.
build_and_install_captdriver() {
    log_step "Tai va bien dich captdriver (ValdikSS/captdriver, nhanh page-streaming)"

    mkdir -p "$(dirname "$BUILD_DIR")"

    if [[ -f "$CAPTDRIVER_BUNDLE" ]]; then
        # Dung goi ma nguon dong san CANH script (khong can mang/GitHub).
        # Giai nen lai TU DAU moi lan de dam bao luon dung, khong lien quan
        # den git/origin-check (goi dong san khong co .git).
        log_info "Dung goi ma nguon co san (khong can tai tu GitHub): $CAPTDRIVER_BUNDLE"
        rm -rf "$BUILD_DIR"
        mkdir -p "$BUILD_DIR"
        if ! tar xzf "$CAPTDRIVER_BUNDLE" -C "$BUILD_DIR" --strip-components=1; then
            log_error "Giai nen goi ma nguon co san that bai: $CAPTDRIVER_BUNDLE"
            return 1
        fi
        log_ok "Da giai nen ma nguon tu goi co san."
    else
        log_info "Khong thay goi ma nguon co san ($CAPTDRIVER_BUNDLE), se tai tu GitHub..."
        # Neu $BUILD_DIR da ton tai nhung tro toi origin KHAC (vd: con sot lai
        # tu ban cai dat cu dung mounaiban/captdriver truoc khi cong cu nay
        # chuyen sang ban ValdikSS - hai ban dung CHUNG duong dan BUILD_DIR)
        # thi khong duoc tai su dung: mounaiban/captdriver khong co nhanh
        # "val", lenh reset se that bai va neu bi nuot loi se vo tinh build
        # lai driver CU. Phai clone lai sach trong truong hop nay.
        if [[ -d "$BUILD_DIR/.git" ]]; then
            git config --global --add safe.directory "$BUILD_DIR" >/dev/null 2>&1 || true
            local current_origin
            current_origin="$(git -C "$BUILD_DIR" remote get-url origin 2>/dev/null || true)"
            if [[ "$current_origin" != "$CAPTDRIVER_REPO" ]]; then
                log_warn "Thu muc build dang tro toi kho nguon khac ('$current_origin', khong phai ValdikSS). Xoa va clone lai sach."
                rm -rf "$BUILD_DIR"
            fi
        fi

        if [[ -d "$BUILD_DIR/.git" ]]; then
            log_info "Da co ma nguon dung kho ValdikSS san, dang cap nhat..."
            if ! timeout "$GIT_TIMEOUT_SECS" git -C "$BUILD_DIR" fetch --all >/dev/null 2>&1 \
                || ! timeout "$GIT_TIMEOUT_SECS" git -C "$BUILD_DIR" reset --hard "origin/${CAPTDRIVER_BRANCH}" >/dev/null 2>&1; then
                log_warn "Cap nhat ma nguon that bai, xoa va clone lai sach."
                rm -rf "$BUILD_DIR"
            fi
        fi

        if [[ ! -d "$BUILD_DIR/.git" ]]; then
            rm -rf "$BUILD_DIR"
            if ! run_step "Clone kho ma nguon captdriver (ValdikSS, nhanh ${CAPTDRIVER_BRANCH})" \
                timeout "$GIT_TIMEOUT_SECS" git clone -b "$CAPTDRIVER_BRANCH" "$CAPTDRIVER_REPO" "$BUILD_DIR"; then
                return 1
            fi
        fi
        git config --global --add safe.directory "$BUILD_DIR" >/dev/null 2>&1 || true
    fi

    # QUAN TRONG: ghi de 3 file nguon da va giao thuc TRUOC khi build. Thieu
    # buoc nay thi rastertocapt build ra la ban goc -> loi ket cung engine o
    # job thu 5 quay lai y nguyen (day chinh la loi cua cac ban script truoc:
    # ma nguon da va nam trong repo nhung khong bao gio duoc dem vao build).
    if ! overlay_captd_patched_sources; then
        log_error "Dung: khong ghi de duoc ma nguon da va (ban va chong treo job 5)."
        return 1
    fi

    pushd "$BUILD_DIR" >/dev/null || { log_error "Khong vao duoc thu muc $BUILD_DIR"; return 1; }

    run_step "Chay autoreconf -vif" autoreconf -vif || { popd >/dev/null; return 1; }
    run_step "Chay ./configure" ./configure || { popd >/dev/null; return 1; }
    make clean >/dev/null 2>&1 || true
    run_step "Bien dich (make)" make || { popd >/dev/null; return 1; }
    run_step "Tao file PPD (make ppd)" make ppd || { popd >/dev/null; return 1; }

    local new_filter="${BUILD_DIR}/src/rastertocapt"
    verify_elf "$new_filter" || { log_error "Filter build ra khong hop le: $new_filter"; popd >/dev/null; return 1; }

    local serverbin filterdir live_filter
    serverbin=$(cups-config --serverbin 2>/dev/null || true)
    [[ -z "$serverbin" ]] && serverbin="/usr/lib/cups"
    filterdir="${serverbin}/filter"
    live_filter="${filterdir}/rastertocapt"
    mkdir -p "$filterdir"

    local orig_owner="root:root" orig_mode="755"
    if [[ -f "$live_filter" ]]; then
        orig_owner="$(stat -c '%U:%G' "$live_filter" 2>/dev/null || echo root:root)"
        orig_mode="$(stat -c '%a' "$live_filter" 2>/dev/null || echo 755)"
        local backup_path="${filterdir}/rastertocapt.bak-$(date +%Y%m%d-%H%M%S 2>/dev/null || echo backup)"
        if ! cp -a "$live_filter" "$backup_path" 2>/dev/null; then
            log_error "Backup filter dang chay THAT BAI. DUNG LAI, KHONG ghi de filter live."
            popd >/dev/null
            return 1
        fi
        log_info "Da backup filter cu -> $backup_path (khong tu xoa)"
    fi

    local tmp_install="${filterdir}/.rastertocapt.new.$$"
    if ! cp -a "$new_filter" "$tmp_install"; then
        log_error "Khong the sao chep filter moi vao ${filterdir}"
        popd >/dev/null
        return 1
    fi
    chown "$orig_owner" "$tmp_install" 2>/dev/null || true
    chmod "$orig_mode" "$tmp_install" 2>/dev/null || true
    if ! verify_elf "$tmp_install"; then
        log_error "Filter sau khi sao chep khong hop le. DUNG LAI, KHONG ghi de."
        rm -f "$tmp_install"
        popd >/dev/null
        return 1
    fi
    mv -f "$tmp_install" "$live_filter" || { log_error "Thay the filter live that bai"; popd >/dev/null; return 1; }

    local ppd_src="${BUILD_DIR}/ppd/CanonLBP-2900-3000.ppd"
    if [[ ! -f "$ppd_src" ]]; then
        log_error "Khong tim thay file PPD sau khi build: $ppd_src"
        popd >/dev/null
        return 1
    fi
    mkdir -p /usr/share/cups/model
    cp -f "$ppd_src" /usr/share/cups/model/
    PPD_PATH="/usr/share/cups/model/CanonLBP-2900-3000.ppd"

    popd >/dev/null
    log_ok "Bien dich va cai dat captdriver hoan tat (ban ValdikSS)."
    log_ok "File filter: ${live_filter}"
    log_ok "File PPD: ${PPD_PATH}"
    return 0
}

# Khoi phuc filter rastertocapt tu ban backup gan nhat (neu muc 5 gay van de moi).
rollback_captdriver_filter() {
    log_step "ROLLBACK: phuc hoi filter rastertocapt ve ban truoc do"
    local serverbin filterdir live_filter latest_backup
    serverbin=$(cups-config --serverbin 2>/dev/null || true)
    [[ -z "$serverbin" ]] && serverbin="/usr/lib/cups"
    filterdir="${serverbin}/filter"
    live_filter="${filterdir}/rastertocapt"

    # Loai .meta ra khoi danh sach: glob "*.bak-*" cung khop file sidecar
    # "*.bak-<timestamp>.meta", va vi .meta duoc ghi SAU binary nen mtime moi
    # hon, "ls -t | head -n1" se chon nham .meta lam "ban backup moi nhat".
    latest_backup="$(ls -1t "${filterdir}"/rastertocapt.bak-* 2>/dev/null | grep -v '\.meta$' | head -n1 || true)"
    [[ -n "$latest_backup" ]] || die "Khong tim thay ban backup nao (${filterdir}/rastertocapt.bak-*)"

    verify_elf "$latest_backup" || die "Ban backup khong hop le, HUY rollback"
    cp -a "$latest_backup" "${live_filter}.rollback-tmp.$$" || die "Sao chep backup that bai"
    mv -f "${live_filter}.rollback-tmp.$$" "$live_filter" || die "Ghi de filter live that bai"
    chown root:root "$live_filter" 2>/dev/null || true
    chmod 755 "$live_filter" 2>/dev/null || true
    log_ok "Da phuc hoi $live_filter tu $latest_backup"
    systemctl restart cups || die "Restart cups that bai sau rollback"
    log_ok "Rollback filter captdriver hoan tat."
}

probe_usb_physical() {
    command -v lsusb >/dev/null 2>&1 || return 1
    lsusb 2>/dev/null | grep -qiE "${VENDOR_ID}:${PRODUCT_ID}|Canon.*CAPT"
}

manual_usb_physical() {
    log_manual "Khong tim thay may in Canon LBP2900/2900B tren cong USB. Vui long:
  1. Kiem tra may in da BAT NGUON va den bao dang sang.
  2. RUT day cap USB ra khoi may tinh, doi khoang 5 giay, roi CAM LAI.
  3. Neu van khong duoc, hay TAT NGUON may in, doi 5 giay, roi BAT LAI.
  4. Thu cam vao mot CONG USB KHAC tren may tinh (tranh dung hub USB neu co the).
  5. Kiem tra day nguon cua may in da cam chac chan vao o dien."
}

probe_cups_uri() {
    local uri
    uri=$(lpinfo -v 2>/dev/null | grep -i 'usb://Canon' | head -n1 | awk '{print $2}')
    if [[ -n "$uri" ]]; then
        CANON_URI="$uri"
        return 0
    fi
    return 1
}

manual_cups_uri() {
    log_manual "May tinh da thay thiet bi Canon tren cong USB, nhung CUPS chua nhan dien duoc.
Nguyen nhan thuong gap: driver 'usblp' cua nhan Linux dang giu thiet bi truoc khi CUPS kip dung. Vui long:
  1. RUT day cap USB ra, doi khoang 5 giay, roi CAM LAI.
  2. Neu van khong duoc, hay TAT NGUON may in, doi 5 giay, roi BAT LAI.
  3. Neu van khong duoc nua, co the can KHOI DONG LAI MAY TINH (sudo reboot) de driver usblp
     khong tu nap lai, sau do chay lai muc nay."
}

detect_usb_printer() {
    log_step "Do tim may in qua USB"
    CANON_URI=""
    local rc

    retry_with_manual_fallback probe_usb_physical manual_usb_physical \
        "phat hien thiet bi USB Canon (lsusb)" 5 2
    rc=$?
    if (( rc == 1 )); then return 1; fi
    if (( rc == 2 )); then
        log_warn "Da bo qua buoc do USB vat ly. Van se thu kiem tra qua CUPS..."
    fi

    udevadm trigger >/dev/null 2>&1 || true
    sleep 1

    retry_with_manual_fallback probe_cups_uri manual_cups_uri \
        "CUPS nhan dien may in (usb://Canon/...)" 5 2
    rc=$?
    if (( rc == 1 )); then return 1; fi
    if (( rc == 2 )); then
        log_warn "Da bo qua buoc xac nhan CUPS. Se dung URI mac dinh usb://Canon/LBP2900."
        CANON_URI="usb://Canon/LBP2900"
    fi

    log_ok "URI may in su dung: ${CANON_URI}"
    return 0
}

register_printer() {
    log_step "Dang ky may in voi CUPS"

    if [[ -z "${PPD_PATH}" || ! -f "${PPD_PATH}" ]]; then
        log_error "Khong tim thay file PPD, khong the dang ky may in."
        return 1
    fi
    # Mac dinh PHAI la capt: (qua captd), khong phai usb:// - dung usb:// la
    # loi ket cung engine o job thu 5 quay lai.
    if [[ -z "${CANON_URI}" ]]; then
        CANON_URI="capt:${CAPTD_SOCK}"
    fi
    if [[ "${CANON_URI}" == usb://* ]]; then
        log_warn "URI dang la ${CANON_URI} (backend usb:// chuan) - se gay ket cung engine o job thu 5."
        log_warn "Chuyen sang capt:${CAPTD_SOCK} (qua captd)."
        CANON_URI="capt:${CAPTD_SOCK}"
    fi

    if ! lpadmin -p "$PRINTER_NAME" -E -v "$CANON_URI" -P "$PPD_PATH"; then
        log_error "lpadmin tao hang doi that bai."
        return 1
    fi
    cupsenable "$PRINTER_NAME" >/dev/null 2>&1 || true
    cupsaccept "$PRINTER_NAME" >/dev/null 2>&1 || true

    log_ok "Da tao hang doi in '${PRINTER_NAME}' voi URI: ${CANON_URI}"

    if ask_yes_no "Dat '${PRINTER_NAME}' lam may in mac dinh?" "y"; then
        if lpadmin -d "$PRINTER_NAME"; then
            log_ok "Da dat '${PRINTER_NAME}' lam may in mac dinh."
        else
            log_warn "Khong the dat '${PRINTER_NAME}' lam may in mac dinh."
        fi
    fi
    return 0
}

# ===========================================================================
# MUC 1 - phan C: DRIVER CANON CHINH HANG v2.71 (thay the driver custom)
# ===========================================================================
# Luu y kien truc quan trong: goi amd64 cua Canon van chua cac binary 32-bit
# (pstocapt, ccpd, captstatusui... la i386), nen tren may 64-bit BAT BUOC phai
# bat kien truc i386 va cai bo thu vien 32-bit tuong ung, neu khong may in se
# "cai xong nhung in khong ra gi" (filter chet luc chay vi thieu thu vien).
# Driver chinh hang giao tiep voi may in qua daemon ccpd + node /dev/usb/lp0
# (module usblp cua kernel) - NGUOC LAI voi driver custom (captdriver dung
# libusb truc tiep qua CUPS usb backend va can usblp PHAI duoc go bo). Vi vay
# hai che do loai tru lan nhau va khi chuyen doi phai don dep che do cu.

# Go file blacklist usblp (neu truoc do cai driver custom co chon blacklist)
# roi nap lai module usblp - driver chinh hang can /dev/usb/lp0 de hoat dong.
ensure_usblp_for_official() {
    log_step "Khoi phuc module usblp (driver chinh hang can /dev/usb/lp*)"
    # captd giu thiet bi USB qua libusb va KHONG NHA ra - neu con chay thi
    # ccpd cua driver chinh hang se khong mo duoc /dev/usb/lp0, dan toi dung
    # trieu chung "bao in thanh cong ma may khong in".
    remove_captd
    local blacklist_file="/etc/modprobe.d/blacklist-usblp.conf"
    if [[ -f "$blacklist_file" ]]; then
        rm -f "$blacklist_file"
        log_info "Da go $blacklist_file (file nay do luc cai driver custom tao ra)."
    fi
    if ! lsmod 2>/dev/null | grep -q '^usblp'; then
        modprobe usblp 2>/dev/null || log_warn "Khong nap duoc module usblp - co the can khoi dong lai may."
    fi
    # ipp-usb van phai dung lai: no se chiem thiet bi USB cua may in truoc ca
    # usblp/cups, gay loi cho moi loai driver.
    systemctl stop ipp-usb >/dev/null 2>&1 || true
    if dpkg -s ipp-usb >/dev/null 2>&1; then
        systemctl disable ipp-usb >/dev/null 2>&1 || true
        systemctl mask ipp-usb >/dev/null 2>&1 || true
    fi
    udevadm trigger >/dev/null 2>&1 || true
    log_ok "Da xu ly xong usblp / ipp-usb cho driver chinh hang."
}

# Cai mot nhom thu vien i386: thu lan luot cac ten goi ung vien (Ubuntu 24.04
# "noble" doi ten nhieu goi sang hau to "t64", vd libatk1.0-0t64) va cai ten
# dau tien ton tai trong kho apt.
install_i386_lib_group() {
    local desc="$1"; shift
    local cand
    for cand in "$@"; do
        if apt-cache show "$cand" >/dev/null 2>&1; then
            if dpkg -l "$cand" 2>/dev/null | grep -q '^ii'; then
                log_info "Da co san: $cand ($desc)"
            elif apt-get install -y "$cand" >/dev/null 2>&1; then
                log_ok "Da cai: $cand ($desc)"
            else
                log_warn "Cai that bai: $cand ($desc) - tiep tuc thu ten goi khac neu co."
                continue
            fi
            return 0
        fi
    done
    log_warn "Khong tim thay goi nao cai duoc cho: $desc (thu: $*)"
    return 1
}

install_canon_official_deps() {
    log_step "Cai goi ho tro cho driver Canon chinh hang (bao gom thu vien 32-bit)"
    apt-get update -y || log_warn "apt-get update gap loi, van tiep tuc thu..."
    if ! apt-get install -y cups cups-client ghostscript usbutils; then
        log_error "Khong cai duoc cac goi co ban (cups, ghostscript...)."
        return 1
    fi

    # Goi amd64 cua Canon chua binary 32-bit -> can thu vien i386.
    if [[ "$(dpkg --print-architecture 2>/dev/null)" == "amd64" ]]; then
        if ! dpkg --print-foreign-architectures 2>/dev/null | grep -qx i386; then
            log_info "Bat kien truc i386 (dpkg --add-architecture i386)..."
            dpkg --add-architecture i386 || { log_error "Khong bat duoc kien truc i386."; return 1; }
            apt-get update -y || log_warn "apt-get update sau khi them i386 gap loi, van tiep tuc thu..."
        fi
        local fail=0
        # Cac thu vien toi thieu de filter pstocapt (32-bit) chay duoc.
        install_i386_lib_group "libc 32-bit"        libc6:i386                                || fail=1
        install_i386_lib_group "libstdc++ 32-bit"   libstdc++6:i386                           || fail=1
        install_i386_lib_group "zlib 32-bit"        zlib1g:i386 zlib1g-t64:i386               || fail=1
        install_i386_lib_group "libpopt 32-bit"     libpopt0:i386 libpopt0t64:i386            || fail=1
        install_i386_lib_group "libxml2 32-bit"     libxml2:i386 libxml2t64:i386              || fail=1
        # Thu vien GTK/glade 32-bit: can cho captstatusui (cua so trang thai).
        # Thieu chung may van in duoc, nen chi canh bao, khong coi la loi.
        install_i386_lib_group "libatk 32-bit"      libatk1.0-0:i386 libatk1.0-0t64:i386      || true
        install_i386_lib_group "libcairo 32-bit"    libcairo2:i386 libcairo2t64:i386          || true
        install_i386_lib_group "libpango 32-bit"    libpango1.0-0:i386 libpango-1.0-0:i386    || true
        install_i386_lib_group "libgtk2 32-bit"     libgtk2.0-0:i386 libgtk2.0-0t64:i386      || true
        install_i386_lib_group "libglade 32-bit"    libglade2-0:i386 libglade2-0t64:i386      || true
        if (( fail == 1 )); then
            log_error "Khong cai du duoc thu vien 32-bit toi thieu - driver chinh hang se khong chay duoc."
            return 1
        fi
    fi
    return 0
}

# Giai nen goi linux-capt-drv-v271-uken.tar.gz va cai 2 goi .deb
# (cndrvcups-common + cndrvcups-capt) dung kien truc cua may.
install_canon_official_driver() {
    log_step "Cai driver Canon chinh hang v2.71 tu goi dong san"

    if [[ ! -f "$CANON_OFFICIAL_BUNDLE" ]]; then
        log_error "Khong tim thay goi driver chinh hang: $CANON_OFFICIAL_BUNDLE"
        log_error "Driver Canon co ban quyen rieng, khong tu dong tai duoc. Hay tai \"CAPT Printer Driver for Linux Version 2.71\" tu trang Canon, dat file linux-capt-drv-v271-uken.tar.gz CANH script nay roi chay lai."
        return 1
    fi

    local workdir
    workdir=$(mktemp -d /tmp/canon-capt-official.XXXXXX) || { log_error "Khong tao duoc thu muc tam."; return 1; }
    if ! tar xzf "$CANON_OFFICIAL_BUNDLE" -C "$workdir"; then
        log_error "Giai nen that bai: $CANON_OFFICIAL_BUNDLE"
        rm -rf "$workdir"
        return 1
    fi

    local deb_dir
    case "$(dpkg --print-architecture 2>/dev/null)" in
        amd64) deb_dir="$workdir/linux-capt-drv-v271-uken/64-bit_Driver/Debian" ;;
        i386)  deb_dir="$workdir/linux-capt-drv-v271-uken/32-bit_Driver/Debian" ;;
        *) log_error "Kien truc he thong khong duoc ho tro boi goi Canon nay."; rm -rf "$workdir"; return 1 ;;
    esac

    local deb_common deb_capt
    deb_common=$(find "$deb_dir" -maxdepth 1 -name 'cndrvcups-common_*.deb' | head -n1)
    deb_capt=$(find "$deb_dir" -maxdepth 1 -name 'cndrvcups-capt_*.deb' | head -n1)
    if [[ -z "$deb_common" || -z "$deb_capt" ]]; then
        log_error "Khong tim thay goi .deb trong $deb_dir - goi tar.gz co the bi loi/khac phien ban."
        rm -rf "$workdir"
        return 1
    fi

    log_info "Cai: $(basename "$deb_common") + $(basename "$deb_capt")"
    # Dung apt-get install voi duong dan file .deb de apt tu giai quyet cac
    # phu thuoc amd64 tu kho (libgtk2.0-0, libglade2-0...) - chac chan hon
    # "dpkg -i" roi "apt-get -f".
    if ! apt-get install -y "$deb_common" "$deb_capt"; then
        log_error "Cai dat goi driver Canon that bai."
        rm -rf "$workdir"
        return 1
    fi
    rm -rf "$workdir"

    dpkg -s cndrvcups-capt >/dev/null 2>&1 || { log_error "Goi cndrvcups-capt chua duoc cai dung."; return 1; }
    [[ -f "$CANON_OFFICIAL_PPD" ]] || { log_error "Khong tim thay PPD sau khi cai: $CANON_OFFICIAL_PPD"; return 1; }

    log_ok "Da cai xong driver Canon chinh hang v2.71 (cndrvcups-capt)."
    return 0
}

# Dam bao daemon ccpd chay va tu khoi dong cung he thong (driver chinh hang
# khong in duoc neu ccpd khong chay). Goi deb chi cai init script SysV, nen
# phai dang ky voi update-rc.d de systemd-sysv-generator tao service tuong ung.
enable_and_start_ccpd() {
    log_step "Bat daemon ccpd (bat buoc cho driver Canon chinh hang)"
    if [[ -f /etc/init.d/ccpd ]]; then
        update-rc.d ccpd defaults >/dev/null 2>&1 || true
    fi
    systemctl daemon-reload >/dev/null 2>&1 || true
    systemctl enable ccpd >/dev/null 2>&1 || true
    if ! systemctl restart ccpd >/dev/null 2>&1; then
        service ccpd start >/dev/null 2>&1 || true
    fi
    sleep 2
    if pgrep -x ccpd >/dev/null 2>&1; then
        log_ok "Daemon ccpd dang chay."
        return 0
    fi
    log_error "Khong khoi dong duoc ccpd. Kiem tra: sudo systemctl status ccpd"
    return 1
}

probe_usblp_node() {
    compgen -G "/dev/usb/lp*" >/dev/null 2>&1
}

manual_usblp_node() {
    log_manual "Khong tim thay node thiet bi /dev/usb/lp* (driver usblp chua nhan may in). Vui long:
  1. Kiem tra may in da BAT NGUON.
  2. RUT day cap USB ra khoi may tinh, doi khoang 5 giay, roi CAM LAI.
  3. Neu van khong duoc, TAT NGUON may in, doi 5 giay, roi BAT LAI.
  4. Thu mot CONG USB KHAC (tranh hub USB neu co the)."
}

# Dang ky may in driver chinh hang: hang doi CUPS dung backend ccp:// + PPD
# Canon, dong thoi khai bao may in voi ccpd (ccpdadmin) tro toi /dev/usb/lp*.
register_printer_official() {
    log_step "Dang ky may in voi CUPS va ccpd (driver chinh hang)"

    local rc
    retry_with_manual_fallback probe_usblp_node manual_usblp_node \
        "node thiet bi /dev/usb/lp* (usblp)" 5 2
    rc=$?
    if (( rc == 1 )); then return 1; fi

    local lpnode=""
    if (( rc == 0 )); then
        lpnode=$(ls /dev/usb/lp* 2>/dev/null | head -n1)
    fi
    if [[ -z "$lpnode" ]]; then
        lpnode="/dev/usb/lp0"
        log_warn "Khong xac dinh duoc node that, dung mac dinh $lpnode."
    fi

    if ! lpadmin -p "$PRINTER_NAME" -E -v "$CANON_OFFICIAL_URI" -P "$CANON_OFFICIAL_PPD"; then
        log_error "lpadmin tao hang doi that bai."
        return 1
    fi
    cupsenable "$PRINTER_NAME" >/dev/null 2>&1 || true
    cupsaccept "$PRINTER_NAME" >/dev/null 2>&1 || true
    log_ok "Da tao hang doi '${PRINTER_NAME}' (URI: ${CANON_OFFICIAL_URI}, PPD: $(basename "$CANON_OFFICIAL_PPD"))"

    log_info "Khai bao may in voi ccpd: $PRINTER_NAME -> $lpnode"
    /usr/sbin/ccpdadmin -p "$PRINTER_NAME" -o "$lpnode" || { log_error "ccpdadmin dang ky that bai."; return 1; }

    enable_and_start_ccpd || return 1
    systemctl restart cups >/dev/null 2>&1 || true

    if ask_yes_no "Dat '${PRINTER_NAME}' lam may in mac dinh?" "y"; then
        if lpadmin -d "$PRINTER_NAME"; then
            log_ok "Da dat '${PRINTER_NAME}' lam may in mac dinh."
        else
            log_warn "Khong the dat '${PRINTER_NAME}' lam may in mac dinh."
        fi
    fi
    return 0
}

# Hanh dong tong hop cho MUC 1 khi nguoi dung chon driver CHINH HANG:
# go sach driver custom (captdriver) roi cai driver Canon v2.71.
action_local_reinstall_official() {
    log_step "=== MUC 1: CAI LBP2900 VOI DRIVER CANON CHINH HANG v2.71 ==="

    # Loai tru cheo: go driver custom (captdriver) neu da cai truoc do.
    cleanup_captdriver_leftovers
    cleanup_cups_queues

    # Driver chinh hang can usblp (/dev/usb/lp*), nguoc voi driver custom.
    ensure_usblp_for_official

    if ! install_canon_official_deps; then
        log_error "Dung: khong cai duoc goi ho tro cho driver chinh hang."
        return 1
    fi

    if ! install_canon_official_driver; then
        log_error "Dung: cai driver Canon chinh hang that bai."
        return 1
    fi

    if ! register_printer_official; then
        log_error "Dang ky may in that bai."
        return 1
    fi

    enable_cups_debug_logging || true

    if detect_lan; then
        log_info "Giao dien: ${LAN_IFACE} | IP may nay: ${LAN_HOST_IP} | Subnet LAN: ${LAN_CIDR}"
        configure_cupsd
        mark_printer_shared
        ensure_avahi
        configure_firewall
        restart_services
        verify_sharing
    else
        log_warn "Khong xac dinh duoc subnet LAN, bo qua chia se qua mang (may in van dung binh thuong tren may nay)."
    fi

    send_test_print "$PRINTER_NAME"

    log_step "HOAN TAT MUC 1 (driver chinh hang)"
    log_ok "Da cai may in '${PRINTER_NAME}' voi driver Canon chinh hang v2.71."
    log_info "Tien ich trang thai cua Canon: captstatusui -P ${PRINTER_NAME}"
    lpstat -p -d 2>&1 || true
    return 0
}

# ===========================================================================
# MUC 5: VA LOI CUPS USB BACKEND (OpenPrinting/cups#1461) - dung chung cho
# muc 1 (cai moi) va muc 5 (ap dung lai cho may da cai truoc do)
# ===========================================================================

cups_backend_already_patched() {
    local serverbin backend
    serverbin=$(cups-config --serverbin 2>/dev/null || true)
    [[ -z "$serverbin" ]] && serverbin="/usr/lib/cups"
    backend="${serverbin}/backend/usb"
    binary_has_string "$backend" "$CUPS_PATCH_MARKER"
}

apply_cups_backend_patch() {
    log_step "Va loi race condition CUPS usb backend (treo im lang khi in tai lieu phuc tap)"

    if cups_backend_already_patched; then
        log_ok "Backend usb dang chay da co dau hieu cua ban va nay. Bo qua build lai."
        return 0
    fi

    local serverbin backend_dir live_backend timestamp
    serverbin=$(cups-config --serverbin 2>/dev/null || true)
    [[ -z "$serverbin" ]] && serverbin="/usr/lib/cups"
    backend_dir="${serverbin}/backend"
    live_backend="${backend_dir}/usb"
    timestamp="$(date +%Y%m%d-%H%M%S 2>/dev/null || echo backup)"

    mkdir -p "$CUPS_PATCH_WORKDIR" || { log_error "Khong tao duoc $CUPS_PATCH_WORKDIR"; return 1; }

    if [[ ! -f "$CUPS_PATCH_SOURCES_FILE" ]]; then
        log_info "Them file deb-src rieng cho Ubuntu noble (khong dung vao file Mint tu quan ly)"
        if [[ -f "$MINT_REPO_FILE" ]]; then
            cp -a "$MINT_REPO_FILE" "${MINT_REPO_FILE}.bak-${timestamp}" 2>/dev/null || true
        fi
        {
            echo "deb-src http://archive.ubuntu.com/ubuntu noble main restricted universe multiverse"
            echo "deb-src http://archive.ubuntu.com/ubuntu noble-updates main restricted universe multiverse"
            echo "deb-src http://security.ubuntu.com/ubuntu/ noble-security main restricted universe multiverse"
        } > "$CUPS_PATCH_SOURCES_FILE"
        if [[ ! -s "$CUPS_PATCH_SOURCES_FILE" ]]; then
            log_error "Ghi $CUPS_PATCH_SOURCES_FILE that bai"
            return 1
        fi
        log_ok "Da tao $CUPS_PATCH_SOURCES_FILE"
    fi

    apt-get update || { log_error "apt-get update that bai. DUNG LAI, chua dong den backend dang chay."; return 1; }
    apt-get install -y build-essential file || { log_error "Cai dat build-essential that bai"; return 1; }
    apt-get build-dep -y cups || { log_error "apt-get build-dep cups that bai"; return 1; }

    ( cd "$CUPS_PATCH_WORKDIR" || exit 1
      # QUAN TRONG: -mindepth 1 - ten cua chinh CUPS_PATCH_WORKDIR
      # ("cups-usb-backend-fix") cung khop pattern 'cups-*', neu thieu
      # -mindepth 1 lenh nay se TU XOA CHINH THU MUC DANG DUNG.
      find "$CUPS_PATCH_WORKDIR" -mindepth 1 -maxdepth 1 -type d -name 'cups-*' -exec rm -rf {} + 2>/dev/null
    )

    ( cd "$CUPS_PATCH_WORKDIR" || exit 1
      # APT mac dinh tai file nguon bang sandbox user "_apt"; thu muc build
      # nam duoi /usr/local/src chi root moi ghi duoc nen _apt se fail voi
      # loi kho hieu "could not open file ... No such file or directory".
      # Override ve root cho rieng lenh nay.
      apt-get -o APT::Sandbox::User=root source cups
    ) || { log_error "apt-get source cups that bai"; return 1; }

    local src_dir
    src_dir="$(find "$CUPS_PATCH_WORKDIR" -mindepth 1 -maxdepth 1 -type d -name 'cups-*' | sort | tail -n1)"
    if [[ -z "$src_dir" || ! -d "$src_dir" ]]; then
        log_error "Khong tim thay thu muc source sau khi apt-get source"
        return 1
    fi
    log_ok "Ma nguon: $src_dir"

    local patch_file="${CUPS_PATCH_WORKDIR}/ca92bf7.patch"
    if [[ -f "$CUPS_PATCH_BUNDLE" ]]; then
        log_info "Dung file patch co san (khong can tai tu GitHub): $CUPS_PATCH_BUNDLE"
        cp -f "$CUPS_PATCH_BUNDLE" "$patch_file" || { log_error "Sao chep file patch co san that bai"; return 1; }
    else
        log_info "Khong thay file patch co san ($CUPS_PATCH_BUNDLE), dang tai tu GitHub..."
        curl -fsSL -o "$patch_file" "$CUPS_PATCH_URL" || { log_error "Tai patch tu GitHub that bai"; return 1; }
    fi
    [[ -s "$patch_file" ]] || { log_error "File patch bi rong"; return 1; }

    (
        cd "$src_dir" || exit 1
        rm -rf .git
        git init -q || exit 1
        git config user.email "cups-backend-fix@local"
        git config user.name "cups-backend-fix"
        git add -A || exit 1
        git commit -q -m "pristine ubuntu source truoc khi va (${timestamp})" || exit 1
        if ! git am --3way "$patch_file"; then
            git am --abort 2>/dev/null || true
            exit 1
        fi
        grep -q "wakeup_pipe" backend/usb-libusb.c || exit 1
    ) || { log_error "Ap dung patch that bai (git am --3way). DUNG LAI, khong build tiep."; return 1; }
    log_ok "Patch da ap dung sach (khong fuzz/reject)"

    (
        cd "$src_dir" || exit 1
        ./configure > "${CUPS_PATCH_WORKDIR}/configure.log" 2>&1 || exit 1
        make -j"$(nproc)" -C cups > "${CUPS_PATCH_WORKDIR}/make-cups.log" 2>&1 || exit 1
        make -j"$(nproc)" -C backend usb > "${CUPS_PATCH_WORKDIR}/make-backend.log" 2>&1 || exit 1
    ) || { log_error "Build that bai, xem log trong ${CUPS_PATCH_WORKDIR}"; return 1; }

    local new_binary="${src_dir}/backend/usb"
    verify_elf "$new_binary" || { log_error "Binary vua build KHONG phai ELF hop le: $new_binary"; return 1; }
    binary_has_string "$new_binary" "$CUPS_PATCH_MARKER" \
        || { log_error "Binary vua build thieu chuoi debug cua patch. Co the build sai, DUNG LAI."; return 1; }
    log_ok "Build thanh cong va da xac minh patch co trong binary."

    [[ -f "$live_backend" ]] || { log_error "Khong tim thay backend dang chay tai $live_backend"; return 1; }
    local orig_owner orig_mode
    orig_owner="$(stat -c '%U:%G' "$live_backend")" || { log_error "Khong doc duoc owner cua $live_backend"; return 1; }
    orig_mode="$(stat -c '%a' "$live_backend")" || { log_error "Khong doc duoc mode cua $live_backend"; return 1; }

    local backup_path="${backend_dir}/usb.bak-${timestamp}"
    cp -a "$live_backend" "$backup_path" || { log_error "Backup binary dang chay THAT BAI. DUNG LAI, KHONG ghi de."; return 1; }
    printf '%s %s\n' "$orig_owner" "$orig_mode" > "${backup_path}.meta" 2>/dev/null || true
    chmod a-w "$backup_path" 2>/dev/null || true
    log_ok "Da backup binary goc -> $backup_path (khong tu xoa)"

    local stage="${CUPS_PATCH_WORKDIR}/usb.to-install"
    cp -a "$new_binary" "$stage" || { log_error "Sao chep binary moi that bai"; return 1; }
    strip --strip-unneeded "$stage" 2>/dev/null || true
    verify_elf "$stage" || { log_error "Binary sau xu ly khong hop le. DUNG LAI."; return 1; }
    binary_has_string "$stage" "$CUPS_PATCH_MARKER" \
        || { log_error "Binary mat dau vet patch sau strip. DUNG LAI de an toan."; return 1; }

    local tmp_install="${backend_dir}/.usb.new-${timestamp}"
    cp -a "$stage" "$tmp_install" || { log_error "Sao chep binary moi vao $backend_dir that bai"; return 1; }
    chown "$orig_owner" "$tmp_install" || { log_error "chown that bai"; return 1; }
    chmod "$orig_mode" "$tmp_install" || { log_error "chmod that bai"; return 1; }
    mv -f "$tmp_install" "$live_backend" || { log_error "Thay the binary live that bai"; return 1; }
    log_ok "Da cai backend usb da va (owner=$orig_owner mode=$orig_mode)"

    if ! systemctl restart cups || ! { sleep 2; systemctl is-active --quiet cups; }; then
        log_error "Restart cups that bai sau khi va. Dang tu dong khoi phuc ban goc..."
        if cp -a "$backup_path" "${live_backend}.autorestore.$$" 2>/dev/null \
            && chown "$orig_owner" "${live_backend}.autorestore.$$" 2>/dev/null \
            && chmod "$orig_mode" "${live_backend}.autorestore.$$" 2>/dev/null \
            && mv -f "${live_backend}.autorestore.$$" "$live_backend" 2>/dev/null \
            && systemctl restart cups >/dev/null 2>&1; then
            log_warn "Da tu dong khoi phuc backend goc, CUPS hoat dong tro lai (chua co ban va)."
        else
            log_error "Tu dong khoi phuc CUNG that bai. Chay ngay: sudo bash $0 --rollback-cups-backend"
        fi
        return 1
    fi
    log_ok "Da va xong loi race condition CUPS usb backend."
    return 0
}

rollback_cups_backend() {
    log_step "ROLLBACK: phuc hoi CUPS usb backend ve ban goc"
    local serverbin backend_dir live_backend latest_backup
    serverbin=$(cups-config --serverbin 2>/dev/null || true)
    [[ -z "$serverbin" ]] && serverbin="/usr/lib/cups"
    backend_dir="${serverbin}/backend"
    live_backend="${backend_dir}/usb"

    # Loai .meta ra khoi danh sach (xem giai thich trong rollback_captdriver_filter).
    latest_backup="$(ls -1t "${backend_dir}"/usb.bak-* 2>/dev/null | grep -v '\.meta$' | head -n1 || true)"
    [[ -n "$latest_backup" ]] || die "Khong tim thay ban backup nao (${backend_dir}/usb.bak-*)"

    verify_elf "$latest_backup" || die "Ban backup khong hop le, HUY rollback"

    local meta_file="${latest_backup}.meta" restore_owner="root:root" restore_mode="755"
    if [[ -f "$meta_file" ]]; then
        read -r restore_owner restore_mode < "$meta_file" 2>/dev/null || true
    fi

    cp -a "$latest_backup" "${live_backend}.rollback-tmp.$$" || die "Sao chep backup that bai"
    chown "$restore_owner" "${live_backend}.rollback-tmp.$$" || true
    chmod "$restore_mode" "${live_backend}.rollback-tmp.$$" || true
    mv -f "${live_backend}.rollback-tmp.$$" "$live_backend" || die "Ghi de backend live that bai"
    log_ok "Da phuc hoi $live_backend tu $latest_backup"

    systemctl restart cups || die "Restart cups that bai sau rollback"
    log_ok "Rollback CUPS backend hoan tat."
}

# ===========================================================================
# MUC 1 - phan B: CHIA SE MAY IN QUA LAN (CUPS/IPP)
# ===========================================================================

configure_cupsd() {
    log_step "Cau hinh CUPS lang nghe & cho phep truy cap tu LAN (${LAN_CIDR})"

    if [[ ! -f "$CUPSD_CONF" ]]; then
        log_error "Khong tim thay $CUPSD_CONF"
        return 1
    fi

    cp -p "$CUPSD_CONF" "${CUPSD_CONF}.bak-$(date +%Y%m%d-%H%M%S 2>/dev/null || echo backup)"

    local need_allow=1
    grep -qF "Allow ${LAN_CIDR}" "$CUPSD_CONF" && need_allow=0

    local tmp
    tmp=$(mktemp)

    awk -v lan="$LAN_CIDR" -v need_allow="$need_allow" '
        BEGIN { in_root_location = 0 }
        /^Listen[ \t]+localhost:631[ \t]*$/ { print "Port 631"; next }
        /^Browsing[ \t]+No[ \t]*$/ { print "Browsing On"; next }
        /^<Location \/>[ \t]*$/ { in_root_location = 1; print; next }
        in_root_location && /^<\/Location>/ {
            in_root_location = 0
            print
            next
        }
        in_root_location && /^[ \t]*Order allow,deny[ \t]*$/ {
            print
            if (need_allow == "1") {
                print "  Allow " lan
            }
            next
        }
        { print }
    ' "$CUPSD_CONF" > "$tmp"

    if ! grep -q "Port 631" "$tmp" && ! grep -qE "^Listen[ \t]+0\.0\.0\.0:631|^Listen[ \t]+\*:631" "$tmp"; then
        log_warn "Khong tim thay dong 'Listen localhost:631' de thay the (co the da duoc cau hinh khac truoc do). Kiem tra thu cong $CUPSD_CONF neu can."
    fi

    cp "$tmp" "$CUPSD_CONF"
    rm -f "$tmp"
    log_ok "Da cap nhat $CUPSD_CONF (ban sao luu: ${CUPSD_CONF}.bak-*)"
}

enable_cups_debug_logging() {
    log_step "Bat LogLevel debug vinh vien cho CUPS (de co du log chi tiet neu co su co sau nay)"

    if [[ ! -f "$CUPSD_CONF" ]]; then
        log_warn "Khong tim thay $CUPSD_CONF, bo qua buoc bat debug log."
        return 0
    fi

    if grep -qE '^LogLevel[ \t]+debug([ \t]|$)' "$CUPSD_CONF"; then
        log_info "LogLevel da la 'debug' tu truoc, bo qua."
        return 0
    fi

    cp -p "$CUPSD_CONF" "${CUPSD_CONF}.bak-$(date +%Y%m%d-%H%M%S 2>/dev/null || echo backup)"

    local tmp
    tmp=$(mktemp)
    if grep -qE '^LogLevel[ \t]' "$CUPSD_CONF"; then
        sed -E 's/^LogLevel[ \t].*/LogLevel debug/' "$CUPSD_CONF" > "$tmp"
    else
        cp "$CUPSD_CONF" "$tmp"
        printf 'LogLevel debug\n' >> "$tmp"
    fi
    cp "$tmp" "$CUPSD_CONF"
    rm -f "$tmp"

    if ! systemctl restart cups; then
        log_warn "Khoi dong lai CUPS that bai sau khi bat debug log (ban sao luu: ${CUPSD_CONF}.bak-*). Kiem tra: sudo systemctl status cups"
        return 1
    fi
    log_ok "Da bat LogLevel debug vinh vien. /var/log/cups/error_log se ghi day du chi tiet (bao gom log chan doan cua captdriver) cho moi lan in - huu ich neu can phan tich su co sau nay, nhung file log se lon hon binh thuong theo thoi gian (logrotate cua he thong van tu dong xoay vong nhu binh thuong)."
}

mark_printer_shared() {
    log_step "Danh dau may in '${PRINTER_NAME}' la shared"
    if ! lpstat -p "$PRINTER_NAME" >/dev/null 2>&1; then
        log_error "Khong tim thay may in '${PRINTER_NAME}' trong CUPS."
        return 1
    fi
    lpadmin -p "$PRINTER_NAME" -o printer-is-shared=true
    log_ok "Da danh dau '${PRINTER_NAME}' la shared."
}

ensure_avahi() {
    log_step "Kiem tra avahi-daemon (mDNS/DNS-SD de cac may khac tu dong do may in)"
    if ! dpkg -s avahi-daemon >/dev/null 2>&1; then
        log_info "Dang cai avahi-daemon..."
        apt-get update -y >/dev/null 2>&1 || true
        apt-get install -y avahi-daemon >/dev/null 2>&1 || { log_warn "Khong cai duoc avahi-daemon (khong chan viec chia se, chi anh huong tu dong do tim)."; return 0; }
    fi
    systemctl enable --now avahi-daemon >/dev/null 2>&1 || true
    if systemctl is-active --quiet avahi-daemon; then
        log_ok "avahi-daemon dang chay."
    else
        log_warn "avahi-daemon khong chay duoc; tu dong do tim co the khong hoat dong, nhung them thu cong bang URL van duoc."
    fi
}

configure_firewall() {
    log_step "Cau hinh firewall (ufw) neu dang bat"
    if ! command -v ufw >/dev/null 2>&1; then
        log_info "Khong cai ufw tren may nay, bo qua buoc firewall."
        return 0
    fi
    if ! ufw status 2>/dev/null | grep -q "Status: active"; then
        log_info "ufw dang tat, khong co gi chan ket noi LAN toi CUPS. Bo qua (se can chay lai muc nay neu ban bat ufw sau nay)."
        return 0
    fi

    if ! ufw status 2>/dev/null | grep -qE "631/tcp.*ALLOW.*${LAN_CIDR}|${LAN_CIDR}.*ALLOW.*631/tcp"; then
        ufw allow from "$LAN_CIDR" to any port 631 proto tcp comment 'CUPS IPP - chia se may in LAN' >/dev/null 2>&1
        log_ok "Da mo cong 631/tcp cho subnet ${LAN_CIDR}"
    else
        log_info "Rule ufw cho 631/tcp tu ${LAN_CIDR} da co san."
    fi

    if ! ufw status 2>/dev/null | grep -qE "5353/udp.*ALLOW.*${LAN_CIDR}|${LAN_CIDR}.*ALLOW.*5353/udp"; then
        ufw allow from "$LAN_CIDR" to any port 5353 proto udp comment 'mDNS/avahi - do tim may in LAN' >/dev/null 2>&1
        log_ok "Da mo cong 5353/udp (mDNS) cho subnet ${LAN_CIDR}"
    else
        log_info "Rule ufw cho 5353/udp tu ${LAN_CIDR} da co san."
    fi
}

restart_services() {
    log_step "Khoi dong lai cups & avahi-daemon de ap dung cau hinh"
    if command -v cupsd >/dev/null 2>&1 && ! cupsd -t 2>/dev/null; then
        log_warn "cupsd -t bao loi cu phap cau hinh; van thu restart, kiem tra ky neu that bai."
    fi
    if ! systemctl restart cups; then
        log_error "Khoi dong lai CUPS that bai. Dang khoi phuc file cau hinh cu..."
        local latest_bak
        latest_bak=$(ls -t "${CUPSD_CONF}".bak-* 2>/dev/null | head -n1)
        if [[ -n "$latest_bak" ]]; then
            cp -p "$latest_bak" "$CUPSD_CONF"
            systemctl restart cups || true
            log_warn "Da khoi phuc cau hinh cu. Kiem tra loi CUPS: sudo journalctl -u cups -n 50"
        fi
        return 1
    fi
    systemctl restart avahi-daemon >/dev/null 2>&1 || true
    log_ok "Da khoi dong lai dich vu."
}

verify_sharing() {
    log_step "Kiem tra ket qua chia se"
    sleep 2
    if ss -tlnp 2>/dev/null | grep -q ':631'; then
        log_ok "cupsd dang lang nghe tren cong 631."
    else
        log_warn "Khong thay cupsd lang nghe tren cong 631 qua 'ss'. Kiem tra: sudo systemctl status cups"
    fi
    echo
    log_ok "URL IPP (dung cho ca Linux va Windows): http://${LAN_HOST_IP}:631/printers/${PRINTER_NAME}"
}

# ===========================================================================
# MUC 1: hanh dong tong hop
# ===========================================================================

action_local_reinstall() {
    log_step "=== MUC 1: GO VA CAI LAI LBP2900 (USB truc tiep tren may nay) ==="

    # Chon loai driver: custom (captdriver ValdikSS, mac dinh - nhe, khong can
    # thu vien 32-bit, da gia co chong treo) hoac Canon CHINH HANG v2.71 (can
    # goi linux-capt-drv-v271-uken.tar.gz canh script + thu vien i386). Hai
    # driver loai tru lan nhau: chon driver nao thi driver kia duoc go sach
    # truoc (custom: cleanup_ccpd go cndrvcups*; chinh hang:
    # cleanup_captdriver_leftovers go rastertocapt).
    if (( DRIVER_OFFICIAL == 1 )) || ask_yes_no "Cai driver Canon CHINH HANG v2.71 thay vi driver custom (captdriver)?" "n"; then
        action_local_reinstall_official
        return $?
    fi

    cleanup_ccpd
    cleanup_cups_queues
    cleanup_captdriver_leftovers
    cleanup_udev
    report_i386_packages

    fix_ipp_usb_and_usblp

    if ! install_build_deps; then
        log_error "Dung: khong cai duoc goi phu thuoc build."
        return 1
    fi

    if ! build_and_install_captdriver; then
        log_error "Dung: build/cai dat captdriver that bai."
        return 1
    fi

    # Khong con va CUPS usb backend o day nua: hang doi in gio dung backend
    # rieng "capt:" (noi toi captd) chu KHONG dung backend usb:// cua CUPS,
    # nen loi race condition cua backend usb khong con anh huong. Ai van muon
    # va backend usb (vd de dung cho may in khac) thi chay MUC 5 rieng.

    if ! detect_usb_printer; then
        log_error "Da huy o buoc do tim may in qua USB."
        return 1
    fi

    # Phai chay SAU detect_usb_printer: ham nay ghi de CANON_URI thanh
    # "capt:<socket>" (detect_usb_printer dat CANON_URI = usb://... chi de
    # xac nhan may in co ton tai that).
    if ! build_and_install_captd; then
        log_error "Dung: build/cai dat captd that bai (day la phan chong loi job 5)."
        return 1
    fi

    if ! register_printer; then
        log_error "Dang ky may in that bai."
        return 1
    fi

    enable_cups_debug_logging || true

    if detect_lan; then
        log_info "Giao dien: ${LAN_IFACE} | IP may nay: ${LAN_HOST_IP} | Subnet LAN: ${LAN_CIDR}"
        configure_cupsd
        mark_printer_shared
        ensure_avahi
        configure_firewall
        restart_services
        verify_sharing
    else
        log_warn "Khong xac dinh duoc subnet LAN, bo qua chia se qua mang (may in van dung binh thuong tren may nay)."
    fi

    send_test_print "$PRINTER_NAME"

    log_step "HOAN TAT MUC 1"
    log_ok "Da go, cai lai va (neu co mang) chia se may in '${PRINTER_NAME}'."
    lpstat -p -d 2>&1 || true
    return 0
}

# ===========================================================================
# MUC 2: CAI QUA MANG TU MAY LINUX KHAC (client)
# ===========================================================================

action_network_client_linux() {
    log_step "=== MUC 2: CAI LBP2900 QUA MANG (client Linux) ==="

    local server_ip
    server_ip=$(ask_value "Nhap dia chi IP cua may chu (noi cam may in LBP2900)" "$DEFAULT_SERVER_IP")

    log_info "Kiem tra ket noi toi may chu ${server_ip}:631 ..."
    if ! curl -s -m 6 -o /dev/null "http://${server_ip}:631/printers/${PRINTER_NAME}"; then
        log_error "Khong ket noi duoc toi http://${server_ip}:631/printers/${PRINTER_NAME}."
        log_error "Kiem tra: may chu da chay MUC 1 (co bat chia se LAN) chua? Dia chi IP dung chua? Hai may cung mang chua?"
        return 1
    fi
    log_ok "Ket noi toi may chu OK."

    if ! command -v lpadmin >/dev/null 2>&1 || ! dpkg -s cups-client >/dev/null 2>&1; then
        log_info "Dang cai cups + cups-client tren may nay..."
        apt-get update -y >/dev/null 2>&1 || true
        if ! apt-get install -y cups cups-client >/dev/null 2>&1; then
            log_error "Khong cai duoc cups/cups-client."
            return 1
        fi
        systemctl enable --now cups >/dev/null 2>&1 || true
    fi

    lpadmin -x "$PRINTER_NAME" >/dev/null 2>&1 || true
    if ! lpadmin -p "$PRINTER_NAME" -E -v "ipp://${server_ip}:631/printers/${PRINTER_NAME}" -m everywhere; then
        log_error "Tao hang doi in (tro toi may chu qua mang) that bai."
        return 1
    fi
    cupsenable "$PRINTER_NAME" >/dev/null 2>&1 || true
    cupsaccept "$PRINTER_NAME" >/dev/null 2>&1 || true
    log_ok "Da tao hang doi '${PRINTER_NAME}' tro toi ipp://${server_ip}:631/printers/${PRINTER_NAME}"

    if ask_yes_no "Dat '${PRINTER_NAME}' lam may in mac dinh?" "y"; then
        lpadmin -d "$PRINTER_NAME" && log_ok "Da dat mac dinh." || log_warn "Khong dat duoc mac dinh."
    fi

    send_test_print "$PRINTER_NAME"

    log_step "HOAN TAT MUC 2"
    log_ok "May nay da dung chung may in '${PRINTER_NAME}' qua mang tu ${server_ip}."
    return 0
}

# ===========================================================================
# MUC 3: HUONG DAN CAI QUA MANG TREN WINDOWS (chi hien text)
# ===========================================================================

action_network_client_windows_guide() {
    log_step "=== MUC 3: HUONG DAN CAI LBP2900 QUA MANG TREN WINDOWS ==="

    local server_ip
    server_ip=$(ask_value "Nhap dia chi IP cua may chu (noi cam may in LBP2900)" "$DEFAULT_SERVER_IP")

    if curl -s -m 6 -o /dev/null "http://${server_ip}:631/printers/${PRINTER_NAME}"; then
        log_ok "May chu ${server_ip} dang chia se may in va co the truy cap duoc tu mang nay."
    else
        log_warn "Khong ket noi duoc toi may chu ${server_ip} tu chinh may nay. Van hien huong dan ben duoi, nhung kiem tra lai IP/may chu truoc khi lam tren Windows."
    fi

    cat <<EOF

May nay dang chay Linux nen KHONG the tu dong cau hinh mot may Windows tu xa.
Xem file "huong-dan-ket-noi-may-in.html" di kem cong cu nay de co huong dan
day du, truc quan (mo bang trinh duyet tren may Windows can ket noi) - trong
do co san file .bat tu dong hoa. Tom tat nhanh:

  1. Vao Settings > Bluetooth & devices > Printers & scanners > Add device
     (may in co the tu xuat hien sau vai giay qua mDNS).

  2. Neu KHONG tu xuat hien:
     - Bam "Add manually" (hoac muc tuong tu "May toi can khong co trong danh sach")
     - Chon "Select a shared printer by name"
     - Nhap dung dia chi nay:
         http://${server_ip}:631/printers/${PRINTER_NAME}
     - Bam Next; Windows se tu dung driver IPP chuan cua no.
       KHONG can cai captdriver hay driver Canon nao tren may Windows,
       vi may chu Linux (${server_ip}) da tu xu ly chuyen doi sang dinh dang CAPT.

  3. In mot trang thu tu Windows de kiem tra.

Luu y: may chu (${server_ip}) phai dang BAT va da chay xong "1) Go va cai
lai LBP2900" (co bat chia se LAN) thi may in moi xuat hien/hoat dong duoc.
EOF
}

# ===========================================================================
# MUC 5: VA LOI TREO KHI IN TAI LIEU PHUC TAP (danh cho may da cai truoc do)
# ===========================================================================

action_fix_complex_document_hang() {
    log_step "=== MUC 5: VA LOI TREO KHI IN TAI LIEU PHUC TAP (nhieu hinh anh) ==="
    log_info "Ap dung 2 ban va da kiem chung thuc te tren LBP2900:"
    log_info "  (a) Va loi race condition CUPS usb backend (OpenPrinting/cups#1461)"
    log_info "  (b) Chuyen sang captdriver ban ValdikSS (co page-streaming)"
    echo

    if ! lpstat -p "$PRINTER_NAME" >/dev/null 2>&1; then
        log_error "Khong tim thay may in '${PRINTER_NAME}' trong CUPS. Hay chay MUC 1 truoc de cai dat."
        return 1
    fi

    local ok_backend=1 ok_driver=1
    apply_cups_backend_patch || ok_backend=0

    if ! build_and_install_captdriver; then
        log_error "Build/cai lai captdriver that bai."
        ok_driver=0
    fi

    # Build lai ca captd/capt-backend cho khop voi filter vua build (2 phan
    # nay phai di cung nhau - filter da va chi hoat dong dung khi di qua captd).
    if ! build_and_install_captd; then
        log_error "Build/cai lai captd that bai."
        ok_driver=0
    fi

    enable_cups_debug_logging || true

    if ! systemctl restart cups >/dev/null 2>&1; then
        log_warn "Khoi dong lai CUPS that bai sau khi cap nhat filter. Kiem tra: sudo systemctl status cups"
    fi

    if (( ok_backend == 0 )) && (( ok_driver == 0 )); then
        log_error "Ca 2 ban va deu that bai. May in van dung binh thuong nhung van co the treo voi tai lieu phuc tap."
        return 1
    fi

    send_test_print "$PRINTER_NAME"

    log_step "HOAN TAT MUC 5"
    if (( ok_backend == 1 )) && (( ok_driver == 1 )); then
        log_ok "Da ap dung ca 2 ban va thanh cong."
    else
        log_warn "Chi ap dung duoc mot phan (xem canh bao o tren). May in van dung duoc nhung co the chua het treo voi tai lieu rat phuc tap."
    fi
    log_info "Neu can khoi phuc: sudo bash $0 --rollback-cups-backend  hoac  --rollback-captdriver-filter"
    return 0
}

# ===========================================================================
# MENU CHINH
# ===========================================================================

show_menu() {
    echo
    echo "===================================================="
    echo "   CONG CU CANON LBP2900 / LBP2900B - MENU CHINH"
    echo "===================================================="
    echo "  1) Go va cai lai LBP2900 (may nay, cam truc tiep USB)"
    echo "  2) Cai LBP2900 qua mang tu may khac (Linux)"
    echo "  3) Cai LBP2900 qua mang tu may khac (Windows) - huong dan"
    echo "  4) Sua loi \"may in khong phan hoi\" (reset USB nhanh)"
    echo "  5) Va loi treo khi in tai lieu phuc tap (nhieu hinh anh)"
    echo "  6) Thoat"
    echo "===================================================="
    echo "   Design by Bruce Nguyen from CCTVWIKI.COM va Claude Code Max"
    echo "===================================================="
}

dispatch() {
    case "$1" in
        1) action_local_reinstall ;;
        2) action_network_client_linux ;;
        3) action_network_client_windows_guide ;;
        4) action_fix_capt_stuck ;;
        5) action_fix_complex_document_hang ;;
        *) log_warn "Lua chon khong hop le."; return 1 ;;
    esac
}

main() {
    require_root "$@"

    if (( ROLLBACK_CUPS_BACKEND == 1 )); then
        rollback_cups_backend
        exit $?
    fi
    if (( ROLLBACK_CAPTDRIVER_FILTER == 1 )); then
        rollback_captdriver_filter
        exit $?
    fi

    if [[ -n "$DIRECT_ACTION" ]]; then
        dispatch "$DIRECT_ACTION"
        exit $?
    fi

    local choice
    while true; do
        show_menu
        read -rp "Chon [1-6]: " choice || { echo; exit 0; }
        case "$choice" in
            6) echo "Tam biet."; exit 0 ;;
            1|2|3|4|5) dispatch "$choice" ;;
            *) log_warn "Lua chon khong hop le, hay go 1-6." ;;
        esac
    done
}

main "$@"
