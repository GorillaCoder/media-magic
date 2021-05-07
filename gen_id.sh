#!/bin/bash
# Generates unique IDs for CDs & DVDs
#
# Ideas:
#-- 1) Make a 'hash' of the track number followed by track length.
#      Requires: initially reading tracks & durations prior to ripping.
#-- 2) Rip first, gather metadata while ripping, move to intended directory
#      afterwards named after collected data.

function id_cd {
   # Given an output like the following:
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
   # and thus directory name for the output.

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


function id_dvd {
   # Given an output like the following:
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

   dvd_title_lengths=$(
      awk '$1=="Title:" {
               sub(/\.[[:digit:]]{3}/, "")
               printf $4
           }' < <(lsdvd /dev/sr0)
   )

   echo $dvd_title_lengths

   #hashed=$( md5sum < <(sed -E 's,[^[:digit:]],,g' <<< "$dvd_title_lengths") )
   #hashed=${hashed%% *}

   #echo $hashed
}

udev_output="$( udevadm info -n /dev/sr0 -q property )"
media_type=$( grep -oE 'ID_CDROM_MEDIA_(CD|DVD)' <<< "$udev_output" )

case $media_type in
   ID_CDROM_MEDIA_CD)
         id_cd ;;

   ID_CDROM_MEDIA_DVD)
         id_dvd ;;
esac
