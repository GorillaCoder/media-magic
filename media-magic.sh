#!/bin/bash
# media-magic.sh, v0.2
#
# changelog
#  2021-05-02  :: Created
#
#───────────────────────────────────( exits )───────────────────────────────────
# My exits:
#  1  :: Disk type not (CD|DVD)
#  2  :: Lock already in place
#  3  :: Exceeded retry times (10)
#  4  :: Must be run as root
#  5  :: DVD mountpoint not empty
#
# External exits: 
#  10x :: vobcopy exited with a non-zero status (x)
#  11x :: abcde exited with a non-zero status (x)
#
#───────────────────────────────────( todo )────────────────────────────────────
#  1) May be able to concat the DVD & CD data files into a single file. I'm not
#     sure if there's a reason to keep them separate, however we will for now.
#     Combining them would allow us to simply the searching functions (could
#     roll into one, raerpb serpt.
#
#═══════════════════════════════════╡ INIT ╞════════════════════════════════════
# Must run as root, else we won't be able to mount drives, run vobcopy, or abcde
[[ $(id -u) -ne 0 ]] && exit 4

#───────────────────────────────────( gvars )───────────────────────────────────
DVD_MOUNTPOINT='/media/cdrom'    # <- Where to mount the CD/DVDs
OUTPUT_DVDS='/mnt/DVDs/raw'      # <- Base path of raw DVD rips. Creates this:
                                 #     $OUTPUT_DVDS/
                                 #       ├─ processing/   (while ripping)
                                 #       ├─ hash/         (when completed)
                                 #       └─ name/         (linked here)

TROGDOR="$( cd "$(dirname "${BASH_SOURCE[0]}")" ; pwd )"
TROGNAME="$(basename "${BASH_SOURCE[0]%.*}")"

DATADIR="${XDG_DATA_HOME:-${HOME}/.local/share}/media-magic"
[[ ! -d "$DATADIR" ]] && mkdir -p "$DATADIR"

# Log file for vobcopy
DVDLOGFILE="${DATADIR}/log"
[[ ! -d "$DVDLOGFILE" ]] && mkdir -p "$DVDLOGFILE"

CDDATAFILE="${DATADIR}/cd-discid.cds"
DVDDATAFILE="${DATADIR}/cd-discid.dvds"
# Text records of the IDs for CDs & DVDs we've scanned. Used when determining if
# a CD we've inserted already exists. It is obtained as follows:
#  $ disk_id_raw=$( cd-discid /dev/sr0 | sed 's, ,_,g' )
# When reading line-by-line:
#  $1 contains the id of the CD
#  $2 contains the path to the album
#
# Create if doesn't exist. `touch` is idempotent--will only update the
# modification time if they exist.
touch "${DATADIR}"/cd-discid.{cds,dvds}

#─────────────────────────────────( functions )─────────────────────────────────
# Creates lockfile to ensure we don't have 2 concurently running `abcde`s. Runs
# in subshell & automatically drops the lock when ripping is completed.
function rip_cd {
   local lockfile="/var/lock/${TROGNAME}.lock"
   (
      flock -e -n 100 || {
         echo "[$TROGNAME]: ERROR: ${lockfile} :: locked" >&2
         exit 2
      }
      /usr/bin/abcde -N -c "${TROGDOR}/abcde.conf"
      # -N :: Noninteractive
      # -c :: Specifies override configuration file
   ) 100>"$lockfile"

   # Exits with abcde's exit status, prefix with '11'. E.g., '114' for an exit
   # status of '4' from abcde.
   [[ $? -ne 0 ]] && exit 11$?

   most_recent_dir=$( find /mnt/CDs/ -type d -exec stat -c '%Y %n' {} \; \
                      | sort -nr \
                      | awk 'NR==1 {print $2}'
   ) ; echo "$disk_id $most_recent_dir" >> "$CDDATAFILE"

   wall "[$TROGNAME] CD RIP FINISHED"
}


function rip_dvd {
   trap 'umount $DVD_MOUNTPOINT 2>/dev/null' EXIT

   # Ensure exists, is is empty
   [[ ! -d "$DVD_MOUNTPOINT" ]] && mkdir -p "$DVD_MOUNTPOINT"
   [[ -n $(ls -A "$DVD_MOUNTPOINT") ]] && exit 5

   mount /dev/sr0 "$DVD_MOUNTPOINT"

   label="$( grep 'ID_FS_LABEL=' <<< "$udev_output" )"
   label="${label#*=}"
   # Example grep output:
   # > ID_FS_LABEL=SHREK
   # > ID_FS_LABEL_ENC=SHREK

   local params=(
      --mirror
      --name "$disk_id"
      --output-dir "$OUTPUT_DVDS/processing"
      -L "$DVDLOGFILE"
      -f # Force overwrite logfile if exists
   ) ; vobcopy "${params[@]}"

   # Exits with vobcopy's exit status, prefix with '10'. E.g., '104' for an exit
   # status of '4' from vobcopy.
   [[ $? -ne 0 ]] && exit 10$?

   # `echo` the label to a file within the directory, just in case:
   echo "$label" > "${OUTPUT_DVDS}/processing/${disk_id}/label"

   # Move files out of processing/ once completed, to the 'hash' directory. The
   # name is the unique ID of the DVD, with spaces replaced by underscores.
   mv "${OUTPUT_DVDS}/processing/${disk_id}"  "${OUTPUT_DVDS}/hash/${disk_id}"

   # Next, generate a friendly name. First try to use the 'label' from the DVD.
   # If there's already a path under this name, add an incrementing numerical
   # suffix until it's unique. E.g., if there's 3 DVDs, for all of whom the
   # label is 'Pride & Prejudice', they will created as follows:
   #  1) 'Pride & Prejudice'
   #  2) 'Pride & Prejudice_2'
   #  3) 'Pride & Prejudice_3'

   # Create temporary 'starting path', so we can potentially add the suffixes
   # below:
   _starting_friendly_path="${OUTPUT_DVDS}/name/${label}"

   # Loop until unique:
   friendly_path="${_starting_friendly_path}"
   while [[ -d "$friendly_path" ]] ; do
      idx=${idx:-2} # <- If no idx yet, start at 2
      friendly_path="${_starting_friendly_path}/name/${label}_${idx}"
      ((idx++))
   done

   # Link from the unique hashed name to the friendly name
   ln -sr "${OUTPUT_DVDS}/hash/${disk_id}"  "$friendly_path" 

   # Log reference from the disk_id to it's friendly path in our data file
   echo "$disk_id $friendly_path" > "${DVDDATAFILE}"

   # Clean & and notify
   umount "$DVD_MOUNTPOINT"
   wall "[$TROGNAME] DVD RIP FINISHED"
}


function dvd_is_found {
   local id_row=$(grep ${disk_id// /_} "$DVDDATAFILE")
   [[ -z "$id_row"  ]] && return 1

   read -r id path <<< "$id_row"
   
   # Sets global var of $FOUND_PATH, so we may access from the `case` statement,
   # or later use in the script to auto-start the media.
   declare -g FOUND_PATH=$path
   return 0
}


function cd_is_found {
   local id_row=$(grep ${disk_id// /_} "$CDDATAFILE")
   [[ -z "$id_row"  ]] && return 1

   read -r id path <<< "$id_row"
   
   # Sets global var of $FOUND_PATH, so we may access from the `case` statement,
   # or later use in the script to auto-start the media.
   declare -g FOUND_PATH=$path
   return 0
}


#═══════════════════════════════════╡ BEGIN ╞═══════════════════════════════════
#───────────────────────────────────( wait )────────────────────────────────────
# Wait until the DVD/CD is actually mounted and readable. `wodim` seems to fully
# pause execution (if a disk is inserted) until we can proceed. May be able to
# drop the max retries from 10.

declare -i counter=0
while true ; do
   [[ $counter -eq 10 ]] && exit 3

   # If we can successfully use `wodim` to read info from the CD/DVD, it's
   # loaded. Ref: https://linux.die.net/man/1/wodim 
   wodim dev=/dev/sr0 -atip &> /dev/null && break  
   
   ((counter++))
done

#──────────────────────────────( find media type )──────────────────────────────
# Get udev info on cdrom, to be parsed later. (Saves us from making multiple
# `udevadm` calls, they take a bit of time).
udev_output="$( udevadm info -n /dev/sr0 -q property )"

# Pull out type: DVD|CD
media_type=$( grep -oE 'ID_CDROM_MEDIA_(CD|DVD)' <<< "$udev_output" )

# Pull CD/DVD identifier, s/ /_/g
disk_id=$( cd-discid /dev/sr0 )
disk_id=${disk_id// /_}

#────────────────────────────────( rip || play )────────────────────────────────
case $media_type in
   ID_CDROM_MEDIA_CD)
         if cd_is_found ; then
            echo "[$TROGNAME] INFO: CD already ripped. Ejecting."
            echo "[$TROGNAME] FOUND: $FOUND_PATH"
            eject
         else
            rip_cd
         fi ;;

   ID_CDROM_MEDIA_DVD)
         if dvd_is_found ; then
            echo "[$TROGNAME] INFO: DVD already ripped. Ejecting."
            echo "[$TROGNAME] FOUND: $FOUND_PATH"
            eject
         else
            rip_dvd
         fi ;;

   *) echo "[$TROGNAME] ERROR: Unable to determine disk type." >&2
      exit 1
      ;;
esac
