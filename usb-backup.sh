#!/bin/bash
# usb-backup.sh — USB / 移动硬盘备份助手（增量快照）
#
# 默认路径可通过下列环境变量覆盖：
#   USB_BACKUP_CONFIG        配置保存路径         (默认 $HOME/.usb-backup.cfg)
#   USB_BACKUP_LOG_DIR       日志目录             (默认 $HOME/.usb-backup-logs)
#   USB_BACKUP_DEFAULT_ROOT  默认备份根目录       (默认 $HOME/Backups)
# 运行前请用 chmod +x 赋予执行权限，如:  bash usb-backup.sh
set -euo pipefail

CONFIG_FILE="${USB_BACKUP_CONFIG:-$HOME/.usb-backup.cfg}"
LOG_DIR="${USB_BACKUP_LOG_DIR:-$HOME/.usb-backup-logs}"
mkdir -p "$LOG_DIR"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
DIM='\033[2m'
NC='\033[0m'

say()      { printf '%b\n' "${CYAN}→${NC} $*" >&2; }
done_msg() { printf '%b\n' "${GREEN}✓${NC} $*" >&2; }
warn()     { printf '%b\n' "${YELLOW}!${NC} $*" >&2; }
err()      { printf '%b\n' "${RED}x${NC} $*" >&2; }
line()     { printf '%b\n' "${DIM}----------------------------------------${NC}" >&2; }

declare -a SNAPSHOTS=()

load_config() {
    declare -gA CFG
    CFG[LAST_USB]=""
    CFG[LAST_TARGET]=""
    if [[ -f "$CONFIG_FILE" ]]; then
        while IFS='=' read -r key value; do
            [[ -z "$key" || "$key" == \#* ]] && continue
            CFG["$key"]="$value"
        done < "$CONFIG_FILE"
    fi
}

save_config() {
    {
        printf 'LAST_USB=%s\n' "${CFG[LAST_USB]}"
        printf 'LAST_TARGET=%s\n' "${CFG[LAST_TARGET]}"
    } > "$CONFIG_FILE"
}

resolve_user_dir() {
    local kind="$1"
    local fallback="$2"
    local path=""

    if command -v xdg-user-dir >/dev/null 2>&1; then
        path=$(xdg-user-dir "$kind" 2>/dev/null || true)
    fi

    if [[ -n "$path" && -d "$path" ]]; then
        printf '%s\n' "$path"
        return
    fi

    if [[ -d "$fallback" ]]; then
        printf '%s\n' "$fallback"
        return
    fi

    printf '%s\n' "$HOME"
}

default_backup_root() {
    printf '%s\n' "${USB_BACKUP_DEFAULT_ROOT:-$HOME/Backups}"
}

mount_field() {
    local path="$1"
    local field="$2"

    if ! command -v findmnt >/dev/null 2>&1; then
        return 1
    fi

    findmnt -T "$path" -n -o "$field" 2>/dev/null | head -1
}

read_input() {
    local prompt="$1"
    local default="${2:-}"
    local answer

    if [[ -n "$default" ]]; then
        printf '%b' "${CYAN}${prompt}${NC} [默认: ${default}] " >&2
    else
        printf '%b' "${CYAN}${prompt}${NC} " >&2
    fi

    IFS= read -r answer
    if [[ -z "$answer" ]]; then
        printf '%s\n' "$default"
    else
        printf '%s\n' "$answer"
    fi
}

confirm_yes() {
    local prompt="$1"
    local default="${2:-N}"
    local answer

    while true; do
        if [[ "$default" == "Y" ]]; then
            answer=$(read_input "$prompt [Y/n]" "Y")
        else
            answer=$(read_input "$prompt [y/N]" "N")
        fi

        case "${answer^^}" in
            Y|YES) return 0 ;;
            N|NO) return 1 ;;
            *) warn "请输入 y 或 n" ;;
        esac
    done
}

ensure_directory() {
    local dir="$1"

    if [[ -d "$dir" ]]; then
        return 0
    fi

    if confirm_yes "目录不存在，是否创建？$dir" "Y"; then
        mkdir -p "$dir"
        done_msg "已创建目录: $dir"
        return 0
    fi

    return 1
}

detect_usb() {
    local devices=()
    local -A seen_dev=()   # 已收录的物理设备(去重 bind/重复挂载)
    while read -r dev mp _; do
        # 只认数据盘: sd* (USB/SATA) 或 nvme*n* (NVMe), 排除 swap 镜像等杂项
        [[ "$dev" =~ ^/dev/(sd[a-z]+|nvme[0-9]+n[0-9]+)(p[0-9]+)?$ ]] || continue
        [[ "$mp" == /boot* || "$mp" == / || "$mp" == /home \
          || "$mp" == /home/Downloads || "$mp" == /home/Downloads/* ]] && continue
        # 去重: 同一物理设备(如 /dev/sda)只取第一个挂载点(首个即主挂载)
        if [[ -n "${seen_dev[$dev]:-}" ]]; then
            continue
        fi
        seen_dev[$dev]=1
        local label="" size=""
        label=$(lsblk -no LABEL "$dev" 2>/dev/null | xargs) || true
        size=$(lsblk -no SIZE "$dev" 2>/dev/null | xargs) || true
        # 无 LABEL 时用挂载点目录名(如 ssd0)而非设备名, 更友好
        [[ -z "$label" ]] && label="$(basename "$mp")"
        devices+=("$mp|$label|$size")
    done < /proc/mounts

    for d in /media/"$USER"/*/ /mnt/*/; do
        [[ -d "$d" ]] || continue
        local mp already=0
        mp="$(realpath "$d")"
        for entry in "${devices[@]}"; do
            [[ "${entry%%|*}" == "$mp" ]] && { already=1; break; }
        done
        (( already )) && continue
        devices+=("$mp|$(basename "$d")|")
    done

    printf '%s\n' "${devices[@]}"
}

choose_usb() {
    local last="$1"
    local usb_entries
    local -a items=()
    local count=0
    local default_choice="c"

    usb_entries=$(detect_usb)

    printf '\n' >&2
    say "可用的 U 盘 / 移动硬盘"
    line

    if [[ -n "$usb_entries" ]]; then
        while IFS= read -r line_text; do
            [[ -z "$line_text" ]] && continue
            IFS='|' read -r mp label size <<< "$line_text"
            local info="$label"
            [[ -n "$size" ]] && info="$label ($size)"
            items+=("$mp")
            count=$((count + 1))
            printf '  %b %s\n' "${CYAN}[$count]${NC}" "$info" >&2
            printf '      %b%s%b\n' "${DIM}" "$mp" "${NC}" >&2
        done <<< "$usb_entries"
        default_choice="1"
    else
        warn "当前没有检测到可用挂载点，可以手动输入路径。"
    fi

    if [[ -n "$last" && -d "$last" ]]; then
        printf '  %b 使用上次的\n' "${CYAN}[u]${NC}" >&2
        printf '      %b%s%b\n' "${DIM}" "$last" "${NC}" >&2
        default_choice="u"
    fi

    printf '  %b 手动输入路径\n' "${CYAN}[c]${NC}" >&2

    while true; do
        local choice custom
        choice=$(read_input "选哪个设备？" "$default_choice")

        case "$choice" in
            u|U)
                if [[ -n "$last" && -d "$last" ]]; then
                    printf '%s\n' "$last"
                    return
                fi
                warn "上次的路径现在不可用。"
                ;;
            c|C)
                custom=$(read_input "输入 U 盘挂载路径")
                if [[ -d "$custom" ]]; then
                    printf '%s\n' "$custom"
                    return
                fi
                err "路径不存在: $custom"
                ;;
            '' )
                ;;
            * )
                if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= count )); then
                    printf '%s\n' "${items[$((choice - 1))]}"
                    return
                fi
                warn "请输入列表里的编号。"
                ;;
        esac
    done
}

choose_target() {
    local last="$1"
    local desktop documents default_target
    local -a targets=()
    local default_choice="1"

    desktop=$(resolve_user_dir DESKTOP "$HOME/Desktop")
    documents=$(resolve_user_dir DOCUMENTS "$HOME/Documents")
    default_target=$(default_backup_root)

    targets=("$default_target" "$desktop" "$documents")

    printf '\n' >&2
    say "备份保存到电脑上的哪个目录？"
    line
    printf '  %b 默认备份目录\n' "${CYAN}[1]${NC}" >&2
    printf '      %b%s%b\n' "${DIM}" "${targets[0]}" "${NC}" >&2
    printf '  %b 桌面\n' "${CYAN}[2]${NC}" >&2
    printf '      %b%s%b\n' "${DIM}" "${targets[1]}" "${NC}" >&2
    printf '  %b 文档\n' "${CYAN}[3]${NC}" >&2
    printf '      %b%s%b\n' "${DIM}" "${targets[2]}" "${NC}" >&2

    if [[ -n "$last" ]]; then
        printf '  %b 使用上次的目录\n' "${CYAN}[u]${NC}" >&2
        printf '      %b%s%b\n' "${DIM}" "$last" "${NC}" >&2
        default_choice="u"
    fi

    printf '  %b 手动输入路径\n' "${CYAN}[c]${NC}" >&2

    while true; do
        local choice custom selected
        choice=$(read_input "存到哪里？" "$default_choice")

        case "$choice" in
            1|2|3)
                selected="${targets[$((choice - 1))]}"
                ensure_directory "$selected" || continue
                printf '%s\n' "$selected"
                return
                ;;
            u|U)
                if [[ -z "$last" ]]; then
                    warn "还没有上次记录。"
                    continue
                fi
                ensure_directory "$last" || continue
                printf '%s\n' "$last"
                return
                ;;
            c|C)
                custom=$(read_input "输入目标目录")
                [[ -n "$custom" ]] || { warn "路径不能为空。"; continue; }
                ensure_directory "$custom" || continue
                printf '%s\n' "$custom"
                return
                ;;
            * )
                warn "请输入 1、2、3、u 或 c。"
                ;;
        esac
    done
}

show_backup_summary() {
    local mode_label="$1"
    local usb="$2"
    local target="$3"
    local logfile="$4"

    printf '\n' >&2
    say "本次操作确认"
    line
    printf '  模式: %s\n' "$mode_label" >&2
    printf '  来源: %s\n' "$usb" >&2
    printf '  目标: %s\n' "$target" >&2
    printf '  日志: %s\n' "$logfile" >&2
    printf '  日志目录: %s\n' "$LOG_DIR" >&2
}

do_full_backup() {
    local usb="$1"
    local target="$2"
    local logfile="$3"

    mkdir -p "$target"

    printf '\n' >&2
    say "开始完整备份"
    line
    printf '  从: %s\n' "$usb" >&2
    printf '  到: %s\n' "$target" >&2
    printf '  日志: %s\n\n' "$logfile" >&2

    rsync -avh --delete --progress \
        --exclude='.cache' \
        --exclude='.Trash*' \
        --exclude='lost+found' \
        --log-file="$logfile" \
        "$usb/" "$target/"

    printf '\n' >&2
    done_msg "完整备份完成。"

    local sz
    sz=$(du -sh "$target" 2>/dev/null | cut -f1 || true)
    [[ -n "$sz" ]] && say "当前目标目录占用: $sz"
}

refresh_latest_link() {
    local target="$1"
    local snapdir="$target/.snapshots"
    local latest_link="$target/latest"
    local newest=""

    rm -f "$latest_link"

    if [[ -d "$snapdir" ]]; then
        newest=$(find "$snapdir" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | sort -r | head -1 || true)
    fi

    if [[ -n "$newest" ]]; then
        ln -sfn "$newest" "$latest_link"
    fi
}

do_incremental_backup() {
    local usb="$1"
    local target="$2"
    local ts="$3"
    local logfile="$4"
    local snapdir="$target/.snapshots"
    local snap last_snap
    local -a link_opt=()

    snap="$snapdir/$ts"
    last_snap=""

    if [[ -d "$snapdir" ]]; then
        last_snap=$(find "$snapdir" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | sort -r | head -1 || true)
    fi

    mkdir -p "$snapdir"

    printf '\n' >&2
    say "开始增量备份"
    line
    printf '  从: %s\n' "$usb" >&2
    printf '  到: %s\n' "$target" >&2
    printf '  快照: %s\n' "$snap" >&2
    printf '  日志: %s\n' "$logfile" >&2

    if [[ -n "$last_snap" ]]; then
        printf '  基线: %s\n\n' "$last_snap" >&2
        link_opt=(--link-dest="$last_snap")
    else
        printf '  基线: 首次备份，本次会完整复制\n\n' >&2
    fi

    rsync -avh --delete --progress \
        --exclude='.cache' \
        --exclude='.Trash*' \
        --exclude='lost+found' \
        "${link_opt[@]}" \
        --log-file="$logfile" \
        "$usb/" "$snap/"

    refresh_latest_link "$target"

    printf '\n' >&2
    done_msg "增量备份完成，快照为 $(basename "$snap")"

    local sz
    sz=$(du -sh "$snap" 2>/dev/null | cut -f1 || true)
    [[ -n "$sz" ]] && say "本次快照目录大小: $sz"
}

list_snapshots() {
    local target="$1"
    local snapdir="$target/.snapshots"
    local latest_real=""
    local i=0

    SNAPSHOTS=()

    if [[ ! -d "$snapdir" ]]; then
        warn "这个目录下还没有任何增量备份记录。"
        return
    fi

    if [[ -L "$target/latest" ]]; then
        latest_real=$(realpath "$target/latest" 2>/dev/null || true)
    fi

    printf '\n' >&2
    say "备份历史"
    line

    while IFS= read -r snap; do
        [[ -z "$snap" ]] && continue
        SNAPSHOTS+=("$snap")
        i=$((i + 1))

        local sz marker
        sz=$(du -sh "$snap" 2>/dev/null | cut -f1 || true)
        marker=""
        [[ -n "$latest_real" && "$snap" == "$latest_real" ]] && marker="  (latest)"
        printf '  %b %s  %s%s\n' "${CYAN}[$i]${NC}" "$(basename "$snap")" "${sz:-未知大小}" "$marker" >&2
    done < <(find "$snapdir" -maxdepth 1 -mindepth 1 -type d | sort -r)

    if (( ${#SNAPSHOTS[@]} == 0 )); then
        warn "快照目录存在，但里面还没有可用记录。"
    fi
}

delete_snapshot() {
    local target="$1"
    list_snapshots "$target"

    if (( ${#SNAPSHOTS[@]} == 0 )); then
        return
    fi

    local num tgt
    while true; do
        num=$(read_input "删掉哪一个？输入编号")
        if [[ "$num" =~ ^[0-9]+$ ]] && (( num >= 1 && num <= ${#SNAPSHOTS[@]} )); then
            tgt="${SNAPSHOTS[$((num - 1))]}"
            break
        fi
        warn "请输入有效编号。"
    done

    printf '\n' >&2
    warn "即将删除: $tgt"
    if ! confirm_yes "确认删除这个快照？" "N"; then
        say "已取消删除。"
        return
    fi

    rm -rf "$tgt"
    refresh_latest_link "$target"
    done_msg "已删除 $(basename "$tgt")"
}

show_header() {
    printf '\n' >&2
    printf '%b\n' "${GREEN}╔══════════════════════════════════════╗${NC}" >&2
    printf '%b\n' "${GREEN}║           U 盘 备 份 助 手           ║${NC}" >&2
    printf '%b\n' "${GREEN}╚══════════════════════════════════════╝${NC}" >&2
    printf '  日志目录: %s\n' "$LOG_DIR" >&2
    printf '\n' >&2
}

main_menu() {
    load_config

    while true; do
        show_header
        printf '  1. 完整备份   把 U 盘当前内容同步到电脑\n' >&2
        printf '  2. 增量备份   生成快照，只保存变化部分\n' >&2
        printf '  3. 查看历史   看现有快照和 latest\n' >&2
        printf '  4. 删除快照   清理旧备份\n' >&2
        printf '  0. 退出\n' >&2

        if [[ -n "${CFG[LAST_USB]:-}" || -n "${CFG[LAST_TARGET]:-}" ]]; then
            printf '\n' >&2
            say "上次使用"
            printf '  U 盘: %s\n' "${CFG[LAST_USB]:-(未记录)}" >&2
            printf '  目录: %s\n' "${CFG[LAST_TARGET]:-(未记录)}" >&2
        fi

        printf '\n' >&2
        local op usb target confirm_text logfile ts
        op=$(read_input "选择操作" "0")

        case "$op" in
            1|2)
                say "第一步，选择 U 盘来源。"
                usb=$(choose_usb "${CFG[LAST_USB]:-}")
                done_msg "已选择来源: $usb"

                say "第二步，选择电脑上的保存目录。"
                target=$(choose_target "${CFG[LAST_TARGET]:-}")
                done_msg "已选择目录: $target"

                CFG[LAST_USB]="$usb"
                CFG[LAST_TARGET]="$target"
                save_config

                if [[ "$op" == "1" ]]; then
                    logfile="$LOG_DIR/full_$(date +%Y%m%d_%H%M%S).log"
                    show_backup_summary "完整备份" "$usb" "$target" "$logfile"
                    confirm_text="确认开始完整备份？"
                else
                    ts=$(date +%Y%m%d_%H%M%S)
                    logfile="$LOG_DIR/incr_${ts}.log"
                    show_backup_summary "增量备份" "$usb" "$target" "$logfile"
                    confirm_text="确认开始增量备份？"
                fi

                if ! confirm_yes "$confirm_text" "N"; then
                    say "已取消本次操作。"
                    continue
                fi

                if [[ "$op" == "1" ]]; then
                    do_full_backup "$usb" "$target" "$logfile"
                else
                    do_incremental_backup "$usb" "$target" "$ts" "$logfile"
                fi
                ;;
            3)
                say "选择要查看历史的备份根目录。"
                target=$(choose_target "${CFG[LAST_TARGET]:-}")
                list_snapshots "$target"
                ;;
            4)
                say "选择要清理的备份根目录。"
                target=$(choose_target "${CFG[LAST_TARGET]:-}")
                delete_snapshot "$target"
                ;;
            0)
                say "退出。"
                exit 0
                ;;
            *)
                warn "只能输入 0、1、2、3、4。"
                ;;
        esac
    done
}

trap 'printf "\n" >&2; say "已取消。"; exit 1' INT TERM

main_menu
