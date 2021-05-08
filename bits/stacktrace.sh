#!/bin/bash
# Testing creating a bash traceback function:

set -o errtrace

trap 'traceback' ERR EXIT
#trap 'stacktrace' ERR EXIT

#function stacktrace {
#   declare frame=0
#   declare argv_offset=0
#
#   while caller_info=( $(caller $frame) ) ; do
#
#       if shopt -q extdebug ; then
#
#           declare argv=()
#           declare argc
#           declare frame_argc
#
#           for ((frame_argc=${BASH_ARGC[frame]},frame_argc--,argc=0; frame_argc >= 0; argc++, frame_argc--)) ; do
#               argv[argc]=${BASH_ARGV[argv_offset+frame_argc]}
#               case "${argv[argc]}" in
#                   *[[:space:]]*) argv[argc]="'${argv[argc]}'" ;;
#               esac
#           done
#           argv_offset=$((argv_offset + ${BASH_ARGC[frame]}))
#           echo ":: ${caller_info[2]}: Line ${caller_info[0]}: ${caller_info[1]}(): ${FUNCNAME[frame]} ${argv[*]}"
#       fi
#
#       frame=$((frame+1))
#   done
#
#   if [[ $frame -eq 1 ]] ; then
#       caller_info=( $(caller 0) )
#       echo ":: ${caller_info[2]}: Line ${caller_info[0]}: ${caller_info[1]}"
#   fi
#}

function traceback {
   declare -i stacklen=$(( "${#FUNCNAME[@]}" - 1 ))

   # For output to terminal:
   table=''
   table+="file\tfunction\tline#\n"
   table+="----\t--------\t-----\n"

   local -i idx
   for idx in $(seq 1 $stacklen) ; do
      fname=${FUNCNAME[-$idx]}
      lineno=${BASH_LINENO[-$idx]}
      file="${BASH_SOURCE[-$idx+1]}"

      table+="${file}\t${fname}\t${lineno}\n"
   done

   #local -i idx
   #for idx in $(seq 1 $stacklen) ; do
   #   c=$( caller $idx )
   #   echo -e "$idx)\t[$c]"
   #done
   #
   #exit

   echo -e  "${table[@]}" | column -t -R 2,3 -s $'\t'
}


function level_1 {
   level_2
}

function level_2 {
   level_3
}

function level_3 {
   exit 3
}

level_1
