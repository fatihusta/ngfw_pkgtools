#! /bin/bash

set -e

usage() {
  echo "Usage: $0 [-s] [-m] -r <repository> -d <distribution>"
  echo "-s : simulate"
  echo "-m : manifest"
  exit 1
}

while getopts "shr:d:m" opt ; do
  case "$opt" in
    s) simulate=1 ;;
    m) MANIFEST=1 ;;
    r) REPOSITORY=$OPTARG ;;
    d) DISTRIBUTION=$OPTARG ;;
    h) usage ;;
    \?) usage ;;
  esac
done
shift $(($OPTIND - 1))
if [ ! $# = 0 ] ; then
  usage
fi

[ -z "$REPOSITORY" -o -z "$DISTRIBUTION" ] && usage && exit 1

pkgtools=`dirname $0`
. $pkgtools/release-constants.sh

tmp_base=/tmp/sync-$REPOSITORY-$DISTRIBUTION-`date -Iminutes`
diffCommand="$pkgtools/apt-chroot-utils/compare-sources.py `hostname`,$REPOSITORY,$DISTRIBUTION user:metavize@updates.untangle.com,$REPOSITORY,$DISTRIBUTION $tmp_base"

# MAIN
if [ -z "$simulate" ] ; then
#  $SSH_COMMAND /etc/init.d/untangle-gpg-agent start
  /bin/rm -f ${tmp_base}*
  [ -n "$MANIFEST" ] && python $diffCommand

  date="`date`"
  $REPREPRO_REMOTE_COMMAND --noskipold update ${DISTRIBUTION}

  # also remove source packages for premium; this is really just a
  # safety measure now, as the update process itself is smarter and
  # knows not to pull sources for premium.
  $SSH_COMMAND ./remove-packages.sh -r ${REPOSITORY} -d ${DISTRIBUTION} -t dsc -c premium

  $REPREPRO_REMOTE_COMMAND export ${DISTRIBUTION}

  local -a attachments
  [ -n "$MANIFEST" ] && attachments=(-a ${tmp_base}.txt -a ${tmp_base}.csv)

  mutt -F $MUTT_CONF_FILE $attachments -s "[$REPOSITORY] `hostname`/$DISTRIBUTION pushed to updates.u.c/$DISTRIBUTION" $RECIPIENT <<EOF
Effective `date` (started at $date).

Attached are the diff files for this push, generated by running
the following command prior to actually promoting:

  $diffCommand

--ReleaseMaster ($USER@`hostname`)

EOF

  /bin/rm -f ${tmp_base}*
#  $SSH_COMMAND /etc/init.d/untangle-gpg-agent stop
else
  $REPREPRO_REMOTE_COMMAND checkupdate $DISTRIBUTION | grep upgraded
  $SSH_COMMAND ./remove-packages.sh -r ${REPOSITORY} -d ${DISTRIBUTION} -t dsc -c premium -s
fi
