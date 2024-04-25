#!/bin/busybox sh

# I am a lazy bastard and there is no busybox out there which does not do process substitution
# If you need this script either compile your busybox with ASH_BASH_COMPAT (like all the other)
# or be so nice and sh-portability-fy the while loop ingests
# shellcheck disable=SC3001

# Dependencies
# efibootmgr    - Nah, not even considering to fiddle with efivars
# blkid         - We need the real one, not the busybox clone
# POSIX tools   - The usual suspects (read, echo, awk, sed, grep)

# Errors
# 255   Mountpoint not found


ESPMODE="${ESPMODE:-"ESP"}"
ESPMNTPTR="${ESPMNTPTR:-"/efis/CurrentBoot"}"
XBLMNTPTR="${XBLMNTPTR:-"/boots/CurrentBoot"}"
VERBOSE="${VERBOSE:-2}"
ERROR=0

dump_partition_meta () {
    local Key Value
    while IFS="=" read -r Key Value
    do
        case "$Key" in 
            DEVNAME) eval "${1}DEV"=\"\$Value\" ;;
            LABEL)
                Value=${Value//\\ / }
                eval "${1}FSLBL"=\"\$Value\"
            ;;
            UUID) eval "${1}FSUUID"=\"\$Value\" ;;
            PARTLABEL)
                Value=${Value//\\ / }
                eval "${1}PTLBL"=\"\$Value\"
            ;;
            PARTUUID) eval "${1}PTUUID"=\"\$Value\" ;;
        esac
    done < <(eval "$2")
}

# Try to find the mountpoint of our device in fstab
find_mount_point () {
    local Key Value Temp
    while IFS=" " read -r SPEC FILE
    do
        [ "${SPEC:0:1}" = "#" ] || [ "${SPEC:0:1}" = "$(echo)" ] && continue # Ignore empty and comment lines
        if [ "$SPEC" = "$(eval "echo \$${1}DEV")" ]; then # Found our mountpoint as /dev
            eval "${1}MOUNT"=\"\$FILE\"
            break
        elif [ "${SPEC:0:1}" = "/" ]; then continue # Skip irelevant /dev
        else
            Key=${SPEC%=*} # Extract key
            Value=${SPEC#*=} # Extract value
            Value=${Value//\"/} # Remove quoting
            Value=${Value//\\040/ } # Remove escaped space in
            case "$Key" in 
                UUID)
                    [ "$Value" = "$(eval "echo \$${1}FSUUID")" ] && \
                    eval "${1}MOUNT"=\"\$FILE\" && break
                ;;
                LABEL)
                    [ "$Value" = "$(eval "echo \$${1}FSLBL")" ] && \
                    eval "${1}MOUNT"=\"\$FILE\" && break
                ;;
                PARTLABEL)
                    [ "$Value" = "$(eval "echo \$${1}PTLBL")" ] && \
                    eval "${1}MOUNT"=\"\$FILE\" && break
                ;;
                PARTUUID)
                    [ "$Value" = "$(eval "echo \$${1}PTUUID")" ] && \
                    eval "${1}MOUNT"=\"\$FILE\" && break
                ;;
            esac
        fi
    done < <(< /etc/fstab awk -F '[ \t]+' '{print $1, $2}')

    Temp="$(eval "echo \$${1}MOUNT")"
    if [ -z "$Temp" ]; then
        [ $VERBOSE -gt 0 ] && echo "Didnt find mountpoint for $1 in fstab !!"
        ERROR="$ERROR -> 255 $1"
    fi
}

dump_vars () {
    echo "=========================================================="
    echo "ESPDISK   : $ESPDISK"
    echo "ESPMODE   : $ESPMODE"
    echo "----------------------------------------------------------"
    echo "ESPDEV    : $ESPDEV"
    echo "ESPMOUNT  : $ESPMOUNT"
    echo "ESPMNTPTR : $ESPMNTPTR"
    echo "ESPFSLBL  : $ESPFSLBL"
    echo "ESPPTLBL  : $ESPPTLBL"
    echo "ESPFSUUID : $ESPFSUUID"
    echo "ESPPTUUID : $ESPPTUUID"
    echo "----------------------------------------------------------"
    echo "XBLDEV    : $XBLDEV"
    echo "XBLMOUNT  : $XBLMOUNT"
    echo "XBLMNTPTR : $XBLMNTPTR"
    echo "XBLFSLBL  : $XBLFSLBL"
    echo "XBLPTLBL  : $XBLPTLBL"   
    echo "XBLFSUUID : $XBLFSUUID"
    echo "XBLPTUUID : $XBLPTUUID"
    echo "----------------------------------------------------------"
    echo "ERROR     : $ERROR"
    echo "=========================================================="
}

# Find the GPT UUID of the ESP we booted from
while IFS=" " read -r BootID Description
do  
    if [ "$BootID" = "BootCurrent:" ]; then
        BootCurrent="$Description"
        continue
    fi
    if [ "Boot$BootCurrent" = "$BootID" ]; then
        ESPUUID=$(echo "$Description" | \
            awk -F '[()]' '{print $2}' | \
            awk -F ',' '{print $3}')
        break
    fi
done < <(   efibootmgr | \
            grep "^BootCurrent:\|^Boot[0-9][0-9][0-9][0-9]" | \
            tr -d '*')

dump_partition_meta "ESP" "/bin/blkid -t PARTUUID=$ESPUUID -o export"
find_mount_point "ESP"

# Get the base disk device of our ESP partition
case $(echo "$ESPDEV" | awk -F '/' '{print $3}') in 
    nvme*)
        ESPDISK=$(echo "$ESPDEV" | awk -F 'p' '{print $1}')
    ;;
    hd*|sd*|vd*) 
        ESPDISK=$(echo "$ESPDEV" | sed 's/[0-9]\+$//')
    ;;
esac

# Try to find a XBOOTLDR partition on the ESP disk
while IFS=" " read -r Partition
do  
    case "/dev/$Partition" in 
        "$ESPDISK"|"$ESPDEV")
            continue
        ;;
        *) 
            if [ "$(/bin/blkid -p /dev/"$Partition" -o export -s PART_ENTRY_TYPE | \
                grep PART_ENTRY_TYPE | \
                awk -F '=' '{print $2}')" = \
                "bc13c2ff-59e6-4262-a352-b275fd6f7172" \
            ]; then # "de94bba4-06d1-4d40-a16a-bfd50179d6ac" "bc13c2ff-59e6-4262-a352-b275fd6f7172"
                ESPMODE="XBL"
                dump_partition_meta "XBL" "/bin/blkid /dev/$Partition -o export"
                find_mount_point "XBL"
                break
            fi 
        ;;
    esac
done < <(<  /proc/partitions grep "$(echo "$ESPDISK" | \
            awk -F '/' '{print $3}')" | \
            awk -F ' ' '{print $4}' \
        )

[ $VERBOSE -gt 1 ] && dump_vars

update_mount_pointer () {
    if [ -L "$1" ]; then
        [ $VERBOSE -gt 0 ] && echo -n "There is a symlink "
        if [ "$(readlink -f "$1")" = "$2" ]; then
            [ $VERBOSE -gt 0 ] && echo "which is correct -> leaving"
            return 0
        else
            [ $VERBOSE -gt 0 ] && echo "which is incorrect -> unlinking"
            unlink "$1"
        fi
    fi
    [ $VERBOSE -gt 0 ] && echo "Creating link $1 -> $2"
    ln -s "$2" "$1"
}


if [ "$ESPMODE" = "XBL" ]; then
    [ $VERBOSE -gt 0 ] && echo "Update pointer ESP: $ESPMNTPTR -> $ESPMOUNT"
    update_mount_pointer $ESPMNTPTR $ESPMOUNT
    [ $VERBOSE -gt 0 ] && echo "Update pointer XBL: $XBLMNTPTR -> $XBLMOUNT"
    update_mount_pointer $XBLMNTPTR $XBLMOUNT
else
    [ $VERBOSE -gt 0 ] && echo "Update pointer ESP: $XBLMNTPTR -> $ESPMOUNT"
    update_mount_pointer $XBLMNTPTR $ESPMOUNT
fi

