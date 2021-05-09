#!/bin/bash
#────────────────────────────────( description )────────────────────────────────
# Fully (hopefully) sets up the environment required for automatic CD & DVD
# ripping/playing.
#
# I'm not 100% sure reloading systemctl is is necessary. May be able to load the
# new units automatically, as it's not an enabled service. Better to be safe.
#
# Please read through this entire script before running. I've done so several
# times. Moving things can be a destructive operation, so double-check we won't
# accidentally nuke anything on the filesystem.
#────────────────────────────────────( end )────────────────────────────────────

read -p "I've reviewed this script before running [y/N]: " ans
[[ ! $ans =~ [Yy](es)? ]] && exit 1

PROGDIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" ; pwd)

#───────────────────────────────( dependencies )────────────────────────────────
declare -a deps=(
   # General dependencies:
   nginx lsdvd libcdio-utils

   # ABCDE dependencies:
   abcde lame eyed3 glyrc imagemagick
   cdparanoia flac cdrecord cd-diskid wodi
)

sudo apt-get update -y
sudo apt-get install -y "${deps[@]}"

#───────────────────────────────( deploy files  )───────────────────────────────
echo "Copying configuration & script files..."

function install_to {
   mode=$1 ; src=$2 ; des=$3
   echo "  ...copying ${src} -> ${dest}"

   install_params=(
      -D                   # Create intermediate directories if not found
      -m $mode             # chmod
      --backup -S '.bak'   # If $dest exists, backup as ${dest}.bak
      "${PROGDIR}/${src}"
      "${dest}" 
   )

   sudo install "${install_params[@]}"
}

# `media-magic` bash script
install_to 755 "${PROGDIR}/media-magic.sh" "/usr/local/bin/"

# `abcde` config file:
install_to 644 "abcde.conf" "/etc/"

# `udev` rule:
install_to 644 "99-media-magic.rules" "/etc/udev/rules.d/"

# `systemd` service:
install_to 644 "${PROGDIR}/media-magic.service"  "/etc/systemd/system/"

# `nginx` config
install_to 644 "${PROGDIR}/media-magic.conf" "/etc/nginx/conf.d/"

# `media-magic.sh`'s own config file
install_to 644 "${PROGDIR}/config" "${HOME}/.config/media-magic/"

#────────────────────────────────( load rules )─────────────────────────────────
# Load rule(s):
echo "Reloading udev to load new rule"
sudo udevadm control --reload

# Reload systemctl:
echo "Reloading systemctl"
sudo systemctl daemon-reload

#────────────────────────────────( next steps )─────────────────────────────────
echo "Next steps:"
echo " 1) Edit base deploy directory in /etc/abcde.conf (line 393)"
echo "    e.g., /media/CDs/raw/"
echo " 2) Edit default paths in ${HOME}/.config/media-magic/config"
echo -e "\nGodspeed.\n"
