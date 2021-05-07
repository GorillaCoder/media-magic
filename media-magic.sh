#!/bin/bash
# vim:ft=bash:foldmethod=marker:commentstring=#%s:foldclose=all
#
# changelog
#  2021-05-02  :: Created
#  2021-05-03  :: Added email notification system.
#  2021-05-04  :: Removed email notification system. Swapped w/ creating .html
#                 files to serve. More elegant. Unified to single database file
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
#  6  :: Config file not found
#  7  :: Must be run as root
#
# External exits: 
#  8x :: abcde exited with a non-zero status (x)
#  9x :: vobcopy exited with a non-zero status (x)
#
#}}}
#───────────────────────────────────( todo )─────────────────────────────────{{{
#  1) Generate a single-file archival copy for music
#
#}}}
#═══════════════════════════════════╡ INIT ╞════════════════════════════════════
[[ $(id -u) -ne 0 ]] && exit 7

trap 'cleanup $?' EXIT INT

function cleanup {
   umount "$DVD_MOUNTPOINT" 2>/dev/null
   eject

   # {{{
   # TODO: Throw some better logging on here. It's possible to get line numbers
   #       with ${BASH_LINENO[@]}, and the function stack with ${FUNCNAME[@]}.
   #       Using the latest function and line# would be invaluable to help the
   #       user determine if an error occurred in our code, or from abcde,
   #       mkdir, or any other 'external' command.
   #
   #       Good discussion here:
   #       https://stackoverflow.com/questions/25492953/bash-how-to-get-the-call-chain-on-errors
   #
   #       Can write my own stack tracing function. That would actually be a
   #       very useful addition to @hre-utils.
   #}}}

   # No reason to bring up the html page on success:
   [[ $1 -eq 0 ]] && exit 0

   case $1 in 
      1)   body="Disk type not CD or DVD: '$media_type'" ;;
      2)   body="Unable to acquire lock."                ;;
      3)   body="Exceeded retries waiting to read CD."   ;;
      4)   body="DVD mountpoint not empty."              ;;
      5)   body="CD staging area not clean."             ;;
      6)   body="Config file not found."                 ;;
      7)   body="Must be run as root."                   ;;
      8*)  body="'abcde' failed with status ${1#8}"      ;;
      9*)  body="'vobcopy' failed with status ${1#9}"    ;;
      *)   body="Unknown error occurred."                ;;
   esac

   build_html
   [[ -n $DISPLAY ]] && xdg-open "$HTML_FILE"

   # Preserve exit status
   exit $1
}


function build_html {
bash <<OUTEREOF
cat <<EOF > "$HTML_FILE"
<html>
  <body>
    <h1> FAILURE </h1>
    <h3> $( date '+%Y/%b/%d %H:%m' ) </h3>
    <p>
      Error (perhaps) is: $body
    </p>
    <hr>
    <p>
      Note: Take any error warnings as only potential options.
      An exit 2, for example, can either mean media-magic was unable to acquire
      the lockfile, <em>or</em> any other intermediate command exited with its
      status 2.
    </p>
    <hr>
    <h3> last vobcopy log (tail -n 10) </h3>
    <pre>
      $(
         while IFS=$'\n' read -r line ; do
            echo "$line <br>"
         done < <(tail -n 10 "${DVD_LOGDIR}/vobcopy_"*)
       )
    </pre>
  </body>
</html>
EOF
OUTEREOF
}

#══════════════════════════════════╡ GLOBAL ╞═══════════════════════════════════
TROGDIR="$( cd "$(dirname "${BASH_SOURCE[0]}")" ; pwd )"
TROGNAME="$(basename "${BASH_SOURCE[0]%.*}")"

#─────────────────────────────────( data dir )──────────────────────────────────
# Base directory for all of our data. Set to the XDG_DATA_HOME default:
DATADIR="${HOME}/.local/share/media-magic"
mkdir -p "$DATADIR"

DVD_MOUNTPOINT="${DATADIR}/cdrom"
mkdir -p "$DVD_MOUNTPOINT"

# Log file for vobcopy
DVD_LOGDIR="${DATADIR}/log"
mkdir -p "$DVD_LOGDIR"

DATAFILE="${DATADIR}/database.txt"
touch "$DATAFILE"
# ^^ Text records of the IDs for CDs & DVDs we've scanned. Used when determining
# if a CD we've inserted already exists. It is obtained as follows:
#  $ disc_id_raw=$( cd-discid /dev/sr0 | sed 's, ,_,g' )
#
# When reading line-by-line:
#  $1 type (CD|DVD)
#  $2 $( `cd-discid` | sed 's, ,_,g'
#  $3 path to directory
#
# Allows easily searching the library. Example, print the path to all DVDs.
#  awk '$1=="DVD" {print $3}'

#───────────────────────────────────( html )────────────────────────────────────
# For notifications, writes a brief .html file with failure results, and brief
# log dump. Dropping here raer than in our home dir so nginx can access it:
HTML_DIR="/var/www/media-magic"
HTML_FILE="${HTML_DIR}/index.html"
mkdir -p "$HTML_DIR"

#────────────────────────────────( load config )────────────────────────────────
# Shifted a few of the variables to a config file, for easier editing on the
# user end:
CONF_FILE="${XDG_CONFIG_HOME:-${HOME}/.config}/media-magic/config"
[[ -e "${CONF_FILE}" ]] && source "${CONF_FILE}" || exit 6

# Ensure directories from config file exist:
mkdir -p "$OUTPUT_CDS"
mkdir -p "$OUTPUT_DVDS"


#═════════════════════════════════╡ FUNCTIONS ╞═════════════════════════════════
#───────────────────────────────────( usage )───────────────────────────────────
function usage {
cat <<EOF
USAGE: $(basename "${BASH_SOURCE[0]}") [-h] [-csmd]

Options:
   -h | --help       Print this message and exit
   -c | --config     \`xdg-open\`s the configuration file in your \$EDITOR
   -s | --status     \`xdg-open\`s the .html output file
   -m | --music      \`xdg-open\`s CD directory
   -d | --dvd        \`xdg-open\`s DVD directory
EOF

exit $1
}

#──────────────────────────────────( get ids )──────────────────────────────────
function get_cd_id {
   # Given an output like the following: {{{
   #
   #   CD-ROM Track List (1 - 12)
   #  #: MSF       LSN    Type   Green? Copy? Channels Premphasis?
   #  1: 00:02:00  000000 audio  false  no    2        no
   #  2: 04:40:02  020852 audio  false  no    2        no
   #  3: 08:31:38  038213 audio  false  no    2        no
   #  4: 12:20:65  055415 audio  false  no    2        no
   #  5: 17:06:65  076865 audio  false  no    2        no
   #  6: 21:03:32  094607 audio  false  no    2        no
   #  7: 25:45:43  115768 audio  false  no    2        no
   #  8: 30:05:39  135264 audio  false  no    2        no
   #  9: 33:30:05  150605 audio  false  no    2        no
   # 10: 37:39:28  169303 audio  false  no    2        no
   # 11: 41:55:23  188498 audio  false  no    2        no
   # 12: 45:31:47  204722 audio  false  no    2        no
   #
   # Going to use the time offsets, in HH:MM:SS format, awking out non-digits.
   # Example:
   #     00:02:00  =>  000200
   #     04:40:02  =>  044002
   #     08:31:38  =>  083138
   # Then `md5sum` the entire result, as to not have a prohibitively long ID,
   # and thus directory name for the output. }}}

   # Parameters to pass to `cd-info` within the `awk` statement
   cd_info_params=(
      --no-ioctl --no-device-info --no-header
      --no-analyze --no-cddb --quiet
   )

   disk_times=$(
      awk '$4=="audio" {
               gsub(/:/, "")
               print $2
           }' < <(cd-info "${cd_info_params}")
   )

   hashed=$( md5sum <<< "$disk_times" )
   echo "${hashed%% *}"
}


function get_dvd_id {
   # Given an output like the following: {{{
   #
   # Disc Title: PRIDE_AND_PREJUDICE
   # Title: 01, Length: 02:08:09.266 Chapters: 17, Cells: 18, Audio streams: 04, Subpictures: 03
   # Title: 02, Length: 00:03:57.000 Chapters: 02, Cells: 02, Audio streams: 01, Subpictures: 00
   # Title: 03, Length: 00:06:03.333 Chapters: 02, Cells: 02, Audio streams: 01, Subpictures: 03
   # Title: 04, Length: 00:08:04.500 Chapters: 02, Cells: 02, Audio streams: 01, Subpictures: 03
   # Title: 05, Length: 00:06:17.934 Chapters: 02, Cells: 02, Audio streams: 01, Subpictures: 03
   # Title: 06, Length: 00:13:08.700 Chapters: 02, Cells: 02, Audio streams: 01, Subpictures: 03
   # Title: 07, Length: 00:00:24.000 Chapters: 02, Cells: 02, Audio streams: 01, Subpictures: 00
   # Title: 08, Length: 00:00:14.000 Chapters: 02, Cells: 02, Audio streams: 01, Subpictures: 00
   # Title: 09, Length: 00:00:10.233 Chapters: 02, Cells: 02, Audio streams: 01, Subpictures: 00
   # Longest track: 01
   #
   # This should be a portable solution, as it only depends on reading the
   # length of every track in the DVD. Should we switch off `lsdvd`, there are
   # certainly other utilities that can provide title length to yield the same
   # result.
   #
   # Lengths should be in HH:MM:SS format, stripping (not rounding) trailing
   # miliseconds, with non-digit characters removed. Example transformation:
   #     02:08:09.266  =>  020809
   #     00:03:57.000  =>  000357
   #     00:06:03.333  =>  000603
   #}}}

   dvd_title_lengths=$(
      awk '$1=="Title:" {
               sub(/\.[[:digit:]]{3}/, "")
               gsub(/:/, "")
               print $4
           }' < <(lsdvd /dev/sr0)
   )

   hashed=$( md5sum <<< "$dvd_title_lengths")
   echo "${hashed%% *}"
}

#──────────────────────────────────( ripping )──────────────────────────────────
# Creates lockfile to ensure we don't have 2 concurrently running `abcde`s. Runs
# in subshell & automatically drops the lock when ripping is completed.
function rip_cd {
   disc_id="$1"

   local lockfile="${DATADIR}/${TROGNAME}.lock"
   (
      flock -e -n 100 || exit 2
      # TODO: take out the -c on in the final edit
      abcde -N -c "${TROGDIR}/abcde.conf" ; rv=$?
   ) 100>"$lockfile"

   # Exits with abcde's exit status, prefix with '8'. E.g., '84' for an exit
   # status of '4' from abcde.
   [[ $rv -ne 0 ]] && exit 8$rv

   # Sadly enough, this seems to be the best way to find the most recently
   # written directory.
   path=$( find "$OUTPUT_CDS/flac" -type d -exec stat --format '%Y %n' {} \; \
           | sort -nr \
           | awk 'NR==1 {print $2}' )

   echo "CD $disc_id $path" >> "$DATAFILE"
}


function rip_dvd {
   disc_id="$1"

   # Ensure mountpoint is empty before mounting:
   [[ -n $(ls -A "$DVD_MOUNTPOINT") ]] && exit 4
   mount /dev/sr0 "$DVD_MOUNTPOINT"

   label="$( grep 'ID_FS_LABEL=' <<< "$udev_output" )"
   label="${label#*=}"
   # Example grep output:
   # > ID_FS_LABEL=SHREK
   # > ID_FS_LABEL_ENC=SHREK

   local params=(
      --mirror
      --name "$disc_id"
      --input-dir "$DVD_MOUNTPOINT"
      --output-dir "$OUTPUT_DVDS/processing"
      -L "$DVD_LOGDIR"
      -f # Force overwrite logfile if exists
   ) ; vobcopy "${params[@]}"

   # Exits with vobcopy's exit status, prefix with '9'. E.g., '94' for an exit
   # status of '4' from vobcopy.
   [[ $? -ne 0 ]] && exit 9$?

   # `echo` the label to a file within the directory, just in case:
   echo "$label" > "${OUTPUT_DVDS}/processing/${disc_id}/label"

   # Move files out of processing/ once completed, to the 'hash' directory. The
   # name is the unique ID of the DVD, with spaces replaced by underscores.
   mv "${OUTPUT_DVDS}/processing/${disc_id}"  "${OUTPUT_DVDS}/hash/${disc_id}"

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
   ln -sr "${OUTPUT_DVDS}/hash/${disc_id}"  "$friendly_path" 

   # Log reference from the disc_id to it's friendly path in our data file
   echo "DVD $disc_id $friendly_path" > "${DATAFILE}"
}


function already_ripped {
   local id_row=$(grep ${disc_id// /_} "$DATAFILE")
   [[ -z "$id_row"  ]] && return 1
   
   read -r cd_type id path <<< "$id_row"
   
   # Sets global var of $FOUND_PATH, so we may access from the `case` statement,
   # or later use in the script to auto-start the media.
   declare -g FOUND_PATH=$path
   return 0
}


#═══════════════════════════════════╡ BEGIN ╞═══════════════════════════════════
#─────────────────────────────────( argparse )──────────────────────────────────
# Couple quick helper options for viewing status and navigating to the specified
# directories a little more quickly:
if [[ $# -gt 0 ]] ; then
   case $1 in
      -h | --help)
            usage 0 ;;

      -s | --status)
            [[ -n $DISPLAY ]] && exec xdg-open "$HTML_FILE"   ;;

      -C | --config)
            exec xdg-open "$CONF_FILE"   ;;

      -c | --cd?)
            exec xdg-open "$OUTPUT_CDS"  ;;

      -d | --dvd?)
            exec xdg-open "$OUTPUT_DVDS" ;;

      *)    usage 1 ;;
   esac
fi

#───────────────────────────────────( wait )────────────────────────────────────
# Wait until the DVD/CD is actually mounted and readable. `wodim` seems to fully
# pause execution (if a disk is inserted) until we can proceed. May be able to
# drop the max retries from 10.

declare -i counter=0
while true ; do
   [[ $counter -eq 10 ]] && exit 3

   # If we can successfully use `wodim` to read info from the CD/DVD, it's
   # loaded. Ref: https://linux.die.net/man/2/wodim 
   wodim dev=/dev/sr0 -atip &> /dev/null && break  
   
   ((counter++))
done

#──────────────────────────────( find media type )──────────────────────────────
# Get udev info on cdrom, to be parsed later. (Saves us from making multiple
# `udevadm` calls, they take a bit of time).
udev_output="$( udevadm info -n /dev/sr0 -q property )"
media_type=$( grep -oE 'ID_CDROM_MEDIA_(CD|DVD)' <<< "$udev_output" )

#────────────────────────────────( rip || play )────────────────────────────────
if already_ripped ; then
   umount "$DVD_MOUNTPOINT" 2>/dev/null
   [[ -n $DISPLAY ]] && exec xdg-open "$FOUND_PATH"
else
   case $media_type in
      ID_CDROM_MEDIA_CD)
            rip_cd $( get_cd_id ) ;;

      ID_CDROM_MEDIA_DVD)
            rip_dvd $( get_dvd_id ) ;;

      *) exit 1 ;;
   esac
fi
