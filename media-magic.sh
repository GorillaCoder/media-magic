#!/bin/bash
# vim:ft=bash:foldmethod=marker:commentstring=#%s
#
# changelog
#  2021-05-02  :: Created
#
#────────────────────────────────( description )─────────────────────────────{{{
#  if cd.id is in database:
#     eject
#     play_locally(cd.id)
#  else:
#     if cd.type == 'CD':
#        rip_cd(cd)
#     elif cd.type == 'DVD':
#        rip_dvd(cd)
#     else:
#        fail_spectacularly()
#     add_to_db(cd_id)
#
#}}}
#───────────────────────────────────( exits )────────────────────────────────{{{
# My exits:
#  1  :: Disk type not 'CD' or 'DVD'
#  2  :: Lock already in place
#  3  :: Retries exceeding waiting for CD
#  4  :: DVD mountpoint not empty
#  5  :: CD staging area not clean
#
# External exits: 
#  2x :: abcde exited with a non-zero status (x)
#  3x :: vobcopy exited with a non-zero status (x)
#
#}}}
#───────────────────────────────────( todo )─────────────────────────────────{{{
#  1) May be able to concat the DVD & CD data files into a single file. I'm not
#     sure if there's a reason to keep them separate, however we will for now.
#     Combining them would allow us to simply the searching functions (could
#     roll into one, raerpb serpt.
#  2) Ensure mime types are set correctly, so we can `xdg-open`.
#     - Maybe this should be part of the `deploy.sh` script
#  3) Currently the local-play functionality does not exist. However it should
#     not be too challenging to implement, as we have an ID -> path mapping.
#  4) Refactor code. Genuinely didn't think this would work after so little
#     testing, so much of the code is a little messy. In particular:
#     - Single database file
#     - Single call to find path in DB, locate executable raerpb path
#  5) I don't like the 'most_recent_dir' functionality. There is certainly a
#     better way of programatically determining what the last written CD was.
#
#}}}
#═══════════════════════════════════╡ INIT ╞════════════════════════════════════
trap 'email_on_failure $?' EXIT

function email_on_failure {
   sudo eject
   [[ $1 -eq 0 ]] && exit 0

   case $1 in 
      1)  body="Disk type not CD or DVD."             ;;
      2)  body="Unable to aquire lock."               ;;
      3)  body="Exceeded retries waiting to read CD." ;;
      4)  body="DVD mountpoint not empty"             ;;
      5)  body="CD staging area not clean"            ;;
      2*) body="'abcde' failed with status ${1#2}"    ;;
      3*) body="'vobcopy' failed with status ${1#3}"  ;;
      *)  body="Unknown error occured."               ;;
   esac

   echo "$body" | mail -s "media-magic FAILURE: $1" "$EMAIL_ADDR"
}

#───────────────────────────────────( gvars )───────────────────────────────────
EMAIL_ADDR=
OUTPUT_CDS=
OUTPUT_DVDS='/mnt/DVDs/raw'      # <- Base path of raw DVD rips. Creates this:
                                 #     $OUTPUT_DVDS/
                                 #       ├─ processing/   (while ripping)
                                 #       ├─ hash/         (when completed)
                                 #       └─ name/         (linked here)

TROGDIR="$( cd "$(dirname "${BASH_SOURCE[0]}")" ; pwd )"
TROGNAME="$(basename "${BASH_SOURCE[0]%.*}")"

DATADIR="${XDG_DATA_HOME:-${HOME}/.local/share}/media-magic"
mkdir -p "$DATADIR"

CD_STAGING="${DATADIR}/cd_staging"
mkdir -p "$CD_STAGING"

DVD_MOUNTPOINT="${DATADIR}/cdrom"
mkdir -p "$DVD_MOUNTPOINT"

# Log file for vobcopy
DVD_LOGFILE="${DATADIR}/log"
mkdir -p "$DVDLOGFILE"

DATAFILE="${DATADIR}/database.txt"
# Text records of the IDs for CDs & DVDs we've scanned. Used when determining if
# a CD we've inserted already exists. It is obtained as follows:
#  $ disk_id_raw=$( cd-discid /dev/sr0 | sed 's, ,_,g' )
# When reading line-by-line:
#  $1 type (CD|DVD)
#  $2 $( `cd-discid` | sed 's, ,_,g'
#  $3 path to directory
#
# Create if doesn't exist. `touch` is idempotent--will only update the
# modification time if they already exist.
touch "$DATAFILE"

#─────────────────────────────────( functions )─────────────────────────────────
# Creates lockfile to ensure we don't have 2 concurently running `abcde`s. Runs
# in subshell & automatically drops the lock when ripping is completed.
function rip_cd {
   local lockfile="${DATADIR}/${TROGNAME}.lock"
   (
      flock -e -n 100 || {
         echo "[$TROGNAME]: ERROR: ${lockfile} :: locked" >&2
         exit 2
      }
      /usr/bin/abcde -N -c "${TROGDIR}/abcde.conf"
      # -N :: Noninteractive
      # -c :: Specifies override configuration file
   ) 100>"$lockfile"

   # Exits with abcde's exit status, prefix with '2'. E.g., '24' for an exit
   # status of '4' from abcde.
   [[ $? -ne 0 ]] && exit 2$?

   mp3_path=$( move_cds_from_staging 'mp3' )
   flac_path=$( move_cd_from_staging 'flac' )

   echo "CD $disk_id $flac_path" >> "$DATAFILE"
}


function move_cds_from_staging {
   output_type=$1

   # How many albums are currently in $CD_STAGING? Should be only the one most
   # recent one. 
   declare -a albums=( "${CD_STAGING}/${output_type}"/*/* )
   len=${#albums[@]}
   [[ $len -gt 1 ]] && exit 5
   
   # TODO: I can't really think of an elegant way of doing this. The intent was:
   #
   #   Initially dropped in:                   │   Then moved to:
   #                                           │
   #     $XDG_DATA_HOME                        │     $OUTPUT_CDS
   #       ├── cd_staging/                     │       ├── flac
   #       │    ├── flac                       │       │    ├── ARTIST
   #       │    │    └── ARTIST                │       │    │    ├── ALBUM
   #       │    │         └── ALBUM            │       │    │    └── other_album
   #       │    └── mp3                        │       │    └── artist1
   #       │         └── ARTIST                │       │         └── album1
   #       │              └── ALBUM            │       └── mp3
   #       ├── cdrom/                          │            ├── ARTIST
   #       ├── database.txt                    │            │    ├── ALBUM
   #       └── log/                            │            │    └── other_album
   #                                           │            └── artist1
   #                                           │                 └── album1
   #                                           │

   echo "$path"
}


function rip_dvd {
   trap 'umount $DVD_MOUNTPOINT 2>/dev/null' EXIT

   # Ensure exists, is is empty
   [[ ! -d "$DVD_MOUNTPOINT" ]] && mkdir -p "$DVD_MOUNTPOINT"
   [[ -n $(ls -A "$DVD_MOUNTPOINT") ]] && exit 4

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

   # Exits with vobcopy's exit status, prefix with '3'. E.g., '34' for an exit
   # status of '4' from vobcopy.
   [[ $? -ne 0 ]] && exit 3$?

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
   echo "DVD $disk_id $friendly_path" > "${DATAFILE}"

   # Clean & and notify
   umount "$DVD_MOUNTPOINT"
}


function cd_already_ripped {
   local id_row=$(grep ${disk_id// /_} "$DATAFILE")
   [[ -z "$id_row"  ]] && return 1

   read -r cd_type id path <<< "$id_row"
   
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
   sudo wodim dev=/dev/sr0 -atip &> /dev/null && break  
   
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
if cd_already_ripped ; then
   echo "[$TROGNAME] Media already found at '$FOUND_PATH'."
else
   case $media_type in
      ID_CDROM_MEDIA_CD)
            rip_cd ;;

      ID_CDROM_MEDIA_DVD)
            rip_dvd ;;

      *) exit 1 ;;
   esac
fi
