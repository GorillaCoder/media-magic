#!/bin/bash
# vim:ft=bash:foldmethod=marker:commentstring=#%s:foldclose=all:expandtab:sw=3:ts=3:sts=3
#
# changelog
#  2021-05-02  :: Created
#  2021-05-03  :: Added email notification system.
#  2021-05-04  :: Removed email notification system. Swapped w/ creating .html
#                 files to serve. More elegant. Unified to single database file
#
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
#  1) [ ] Generate a single-file archival copy for music
#  2) [ ] Swap my exit statues to negative values to make unique
#  3) [ ] Maybe start a tmux session (if none exists), and run the script within it.
#         Can then easily check the ongoing status on any machine, getting more than
#         only a snapshot with `systemctl status`.
#  4) [X] When using `lsdvd`, the final line shows the longest track (which is
#         probably the actual movie itself). Should write an additional file to the
#         DVD directory with the path to the track. Can then open with a:
#            $ xdg-open $(cat ${path}/longest_track)
#  5) [X] Ended up using some implicitly globally declared variables from funcs
#         elseware. Maybe swap them to caps w/ a `declare -g` to make it more
#         explicit.
#           1. $friendly_path
#           2. $media_type
#  6) [ ] Vars for executables. Must use `gawk`
#  7) [ ] Easier method to edit the database
#  8) [ ] Ability to call individual functions. E.g., only output the generated
#         id, but don't play or rip
#}}}
#═══════════════════════════════════╡ INIT ╞════════════════════════════════════
#                               hacky tmp fixes
# Enables debug `print` statements throughout the script
_debug=true

# TODO: All the initial dumb settings we need to do for now. Come back and fix
#       these later
HOME=${HOME:-/root}
umount /dev/sr0 2>/dev/null

LOGFILE=/var/log/media-magic
#-------------------------------------------------------------------------------

# Are we root? Fuckin' better be.
if [[ $(id -u) -ne 0 ]] ; then
   echo "Must be run as root."
   exit 7
fi

trap 'cleanup $?' EXIT INT

function cleanup {
   # TODO: HACKY_GARBAGE: :DEBUG:
   [[ $1 -gt 240 ]] && exit 0
   # Gives us 15 exits of our 'own'.

   umount "$DVD_MOUNTPOINT" 2>/dev/null
   eject

   # TODO: {{{
   #       ---
   #       Throw some better logging on here. It's possible to get line numbers
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
   #       ---
   #       }}}
   # For now, until I get the above idea working:
   stacktrace=''
   if [[ ${#FUNCNAME[@]} -gt 1 ]] ; then
      stacktrace="${FUNCNAME[1]}"
   fi

   if [[ $1 -eq 0 ]] ; then
      build_html_success
   else
      case $1 in 
         1)   exit_msg="exit($1) :: Disk type not CD or DVD: '$media_type'"    ;;
         2)   exit_msg="exit($1) :: Unable to acquire lock."                   ;;
         3)   exit_msg="exit($1) :: Exceeded retries waiting to read disc."    ;;
         4)   exit_msg="exit($1) :: DVD mountpoint not empty."                 ;;
         5)   exit_msg="exit($1) :: CD staging area not clean."                ;;
         6)   exit_msg="exit($1) :: Config file not found."                    ;;
         7)   exit_msg="exit($1) :: Must be run as root."                      ;;
         8*)  exit_msg="exit($1) :: 'abcde' failed with status ${1#8}"         ;;
         9*)  exit_msg="exit($1) :: 'vobcopy' failed with status ${1#9}"       ;;
         *)   exit_msg="exit($1) :: Unknown error occurred."                   ;;
      esac
      build_html_failure
   fi

   [[ -n $DISPLAY ]] && xdg-open "$HTML_FILE"

   # Preserve exit status
   exit $1
}


function build_html_success {
bash <<OUTEREOF
cat <<EOF > "$HTML_FILE"
<html>
  <body>
    <hr>
    <h1> SUCCESS </h1>
    <p> Read ${media_type} to ${friendly_path:-$FOUND_PATH} </p>
  </body>
</html>
EOF
OUTEREOF
}


function build_html_failure {
bash <<OUTEREOF
cat <<EOF > "$HTML_FILE"
<html>
  <body>
    <h1> FAILURE </h1>
    <h3> $( date '+%d %b, %H:%m' ) </h3>
    <p>
      $exit_msg
    </p>
    <hr>
    <p>
      Note: Take error descriptions with far more salt than Papa typically cooks with.<br>
      <br>
      An exit 2, for example, can either mean media-magic was unable to acquire
      the lockfile, <em>or</em> any other intermediate command exited with its
      status 2.<br>
      Likewise, error 82 <em>could</em> mean abcde exited with error code '2',
      or another command exited with 82.<br>
      <br>
      "They're more like... 'guidelines'."
    </p>
    <hr>
    $(
       if [[ -n $stacktrace ]] ; then
          echo "Last function called: <strong>$stacktrace()</strong>"
          echo "<hr>"
       fi
    )
    <h3> vobcopy log ($( stat --format '%y' "${DVD_LOGDIR}/vobcopy_1.2.0.log" )) </h3>
    <pre>$(
         while IFS=$'\n' read -r line ; do
            echo "${line}<br>"
         done < <(tail -n 10 "${DVD_LOGDIR}/vobcopy_1.2.0.log")
      )</pre>
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
CONF_FILE="${HOME}/.config/media-magic/config"
[[ -e "${CONF_FILE}" ]] && source "${CONF_FILE}" || exit 6

# Ensure directories from config file exist:
mkdir -p "$DVD_MOUNTPOINT"
mkdir -p "$OUTPUT_CDS"
mkdir -p "${OUTPUT_DVDS}/processing"
mkdir -p "${OUTPUT_DVDS}/hash"
mkdir -p "${OUTPUT_DVDS}/name"
# TODO: do a `mkdir` here better.

#═════════════════════════════════╡ FUNCTIONS ╞═════════════════════════════════
#───────────────────────────────────( usage )───────────────────────────────────
function usage {
cat <<EOF
USAGE: $(basename "${BASH_SOURCE[0]}") [-h] [-csmd] [-f PATTERN]

Options:
   -h | --help          Print this message and exit
   -c | --config        \`xdg-open\`s the configuration file in your \$EDITOR
   -s | --status        \`xdg-open\`s the .html output file
   -c | --cd            \`xdg-open\`s CD directory
   -d | --dvd           \`xdg-open\`s DVD directory
   -f | --find PATTERN  \`grep -iE PATTERN\`
EOF

exit $1
}

#───────────────────────────────────( debug )───────────────────────────────────
function debug {
   local text=$1
   local lineno=${BASH_LINENO[0]}
   local fname=$(basename "${BASH_SOURCE[0]}")

   $_debug && printf "[${fname%.*}] DEBUG(%03d) ${text}\n" $lineno | tee -a "$LOGFILE"
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
   # Using the time offsets, in HH:MM:SS format, awking out non-digits.
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

   # Writing this to the CD_OUTPUT directory for later.
   declare -g cd_info=$(cd-info "${cd_info_params[@]}")

   disk_times=$(
      gawk '$4=="audio" {
                gsub(/:/, "")
                print $2
            }' <<< "$cd_info"
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

   declare -g dvd_info=$(lsdvd /dev/sr0)

   dvd_title_lengths=$(
      awk '$1=="Title:" {
               sub(/\.[[:digit:]]{3}/, "")
               gsub(/:/, "")
               print $4
           }' <<< "$dvd_info"
   )

   declare -G LONGEST_TRACK=$(
      awk '/^Longest track:/ {print $3}' <<< "$dvd_info"
   )

   hashed=$( md5sum <<< "$dvd_title_lengths" )
   echo "${hashed%% *}"
}

#──────────────────────────────────( ripping )──────────────────────────────────
# Creates lockfile to ensure we don't have 2 concurrently running `abcde`s. Runs
# in subshell & automatically drops the lock when ripping is completed.
function rip_cd {
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
   declare -g friendly_path=$(
         find "$OUTPUT_CDS/flac" -type d -exec stat --format '%Y %n' {} \; \
         | sort -nr \
         | awk 'NR==1 {print $2}'
   )

   echo "$cd_info" > "${path}/cd-info"
   echo "CD $disc_id $path" >> "$DATAFILE"
}


function rip_dvd {
   # To avoid race condition between Kubuntu's auto DVD mount:
   existing_mountpoint=$(
         lsblk --list --noheadings -o name,mountpoint \
         | awk '$1=="sr0" {print $2}'
   )
   [[ "$existing_mountpoint" -ne "$DVD_MOUNTPOINT" ]] && umount /dev/sr0

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

   # Write metadata to files in the DVD directory:
   #  1. Label may be useful if we fail the name generation below
   #  2. Output of `lsdvd`
   #  3. LONGEST_TRACK number was obtained from `lsdvd` in get_dvd_id()
   echo "$label"         > "${OUTPUT_DVDS}/processing/${disc_id}/label"
   echo "$dvd_info"      > "${OUTPUT_DVDS}/processing/${disc_id}/dvd-info"
   echo "$LONGEST_TRACK" > "${OUTPUT_DVDS}/processing/${disc_id}/longest_track"

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
   declare -g friendly_path="${_starting_friendly_path}"
   while [[ -d "$friendly_path" ]] ; do
      idx=${idx:-2} # <- If no idx yet, start at 2
      friendly_path="${_starting_friendly_path}/name/${label}_${idx}"
      ((idx++))
   done

   # Link from the unique hashed name to the friendly name
   ln -sr "${OUTPUT_DVDS}/hash/${disc_id}"  "$friendly_path" 

   # Log reference from the disc_id to it's friendly path in our data file
   echo "DVD $disc_id $friendly_path" >> "${DATAFILE}"
}


function already_ripped {
   debug "Checking if CD is in database"
   debug "grep [${disc_id}] [$DATAFILE]"

   local id_row=$(grep $disc_id "$DATAFILE")
   [[ -z "$id_row"  ]] && {
      debug "Not found in database"
      return 1
   }
   
   read -r cd_type id path <<< "$id_row"
   debug "FOUND IN DATABASE: $id_row"
   
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
            [[ -n $DISPLAY ]] && exec xdg-open "$HTML_FILE" ;;

      -C | --config)
            exec ${EDITOR:-vi} "$CONF_FILE" ;;

      -c | --cd*)
            if [[ -n $DISPLAY ]] ; then
               exec xdg-open "$OUTPUT_CDS"
            else
               echo "$OUTPUT_CDS"
            fi ;;

      -d | --dvd*)
            if [[ -n $DISPLAY ]] ; then
               exec xdg-open "$OUTPUT_DVDS"
            else
               echo  "$OUTPUT_DVDS"
            fi ;;

      -f | --find)
            shift
            grep -iE "$1" "${DATAFILE}" | column -t
            ;;

      --disable)
            debug "Creating disable file"
            touch "${DATADIR}/disable"
            ;;

      --enable)
            debug "Removing disable file"
            rm "${DATADIR}/disable" 2>/dev/null
            ;;

      *)    usage 1 ;;
   esac
   
   exit -2
fi

# Don't do anything if --disable is set
if [[ -e "${DATADIR}/disable" ]] ; then
	debug "Disable file found. Exiting."
	exit -1
fi

#───────────────────────────────────( wait )────────────────────────────────────
# Wait until the DVD/CD is actually mounted and readable. `wodim` seems to fully
# pause execution (if a disk is inserted) until we can proceed. May be able to
# drop the max retries from 10.

debug "ENGAGE"

declare -i counter=0
while true ; do
   [[ $counter -eq 10 ]] && exit 3

   # If we can successfully use `wodim` to read info from the CD/DVD, it's
   # loaded. Ref: https://linux.die.net/man/2/wodim 
   wodim dev=/dev/sr0 -atip &> /dev/null && break  
   
   sleep 1
   ((counter++))
done

debug "Disk read successfully"

#──────────────────────────────( find media type )──────────────────────────────
# Get udev info on cdrom, to be parsed later. (Saves us from making multiple
# `udevadm` calls, they take a bit of time).
udev_output="$( udevadm info -n /dev/sr0 -q property )"
media_type=$( grep -oE 'ID_CDROM_MEDIA_(CD|DVD)' <<< "$udev_output" )

debug "Type: ${media_type}"
debug "beginning \`case\`"

# TODO: {{{
#       ---
#       I had to rework how this section do. Used to be structured as follows:
#          >>> if already_ripped
#          ...    eject
#          ...    exec xdg-open $FOUND_PATH
#          ... else
#          ...    case cd.type in:
#          ...       CD)  rip_cd
#          ...       DVD) rip_dvd
#          ...       *)   throw UnknownDiscType
#          ...    esac
#          ... esac
#       The new version has a different method to generate IDs depending if is a
#       CD or DVD. Unfortunately that means we need to put it in the case
#       statement. Sufficiently less clean than it was previously.
#       ---
#       }}}
case $media_type in
   ID_CDROM_MEDIA_CD)
         disc_id=$( get_cd_id )
         debug "ID determined to be $disc_id"
         if already_ripped ; then
            umount "$DVD_MOUNTPOINT" 2>/dev/null
            wall "Disc already ripped: $(basename "${FOUND_PATH}")"
            #[[ -n $DISPLAY ]] && exec xdg-open "$FOUND_PATH"
            #notify-send --urgency=critical "Disc already ripped: $(basename "${FOUND_PATH}")"
         else
            rip_cd
         fi ;;

   ID_CDROM_MEDIA_DVD)
         disc_id=$( get_dvd_id )
         debug "ID determined to be $disc_id"
         if already_ripped ; then
            umount "$DVD_MOUNTPOINT" 2>/dev/null
            wall "Disc already ripped: $(basename "${FOUND_PATH}")"
            #[[ -n $DISPLAY ]] && exec xdg-open "$FOUND_PATH"
            #notify-send --urgency=critical "Disc already ripped: $(basename "${FOUND_PATH}")"
         else
            rip_dvd
         fi ;;

   *) exit 1 ;;
esac
