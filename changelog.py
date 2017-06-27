#! /usr/bin/env python3

import argparse, datetime, git, logging, os, re, sys
import os.path as osp

# FIXME/TODO
# - use static SSH config ?
# 

## constants
PROJECT = "NGFW"
BASE_DIR = osp.join("/tmp", os.getenv('USER'))
REMOTE_TPL = "git@github.com:untangle/{}_{}.git".format(PROJECT.lower(),'{}')
BRANCH_TPL = "origin/release-{}"
REPOSITORIES = ("src", "pkgs", "hades-pkgs", "isotools-jessie")
JIRA_FILTER = re.compile(r'{}-\d+'.format(PROJECT))
CHANGELOG_FILTER = re.compile(r'#changelog|drop') # FIXME

## CL options
parser = argparse.ArgumentParser(description='''List changelog entries
between tags accross multiple repositories.

It can also optionally create and push additional tags, of the form
X.Y.Z-YYYYmmddTHHMM-(promotion|sync)''')

def fullVersion(o):
  if len(o.split('.')) != 3:
    raise argparse.ArgumentTypeError("Not a valid full version (x.y.z)")
  else:
    return o

parser.add_argument('--log-level', dest='logLevel',
                    choices=['debug', 'info', 'warning'],
                    default='warning',
                    help='level at which to log')
parser.add_argument('--tag-type', dest='tagType', action='store',
                    choices=('promotion','sync'),
                    default=None,
                    required=True,
                    metavar="TAG-TYPE",
                    help='tag type')
parser.add_argument('--create-tags', dest='createTags',
                    action='store_true',
                    default=False,
                    help='create new tags (default=no tag creation)')
parser.add_argument('--version', dest='version',
                    action='store',
                    required=True,
                    default=None,
                    metavar="VERSION",
                    type=fullVersion,
                    help='the version on which to base the diff. It needs to be of the form x.y.z, that means including the bugfix revision')

## functions
def formatCommit(commit, repo, tickets = None):
  s = "{} [{}] {}".format(str(commit)[0:7], repo, commit.summary)
  if not tickets:
    return s
  else:
    return "{} ({})".format(s, ", ".join(tickets))

def generateTag(version, tagType):
  ts = datetime.datetime.now().strftime('%Y%m%dT%H')
  return "{}-{}-{}".format(version, ts, tagType)

def updateRepo(name):
  d = osp.join(BASE_DIR, name)
  repoUrl = REMOTE_TPL.format(name)
  logging.info("looking at {}".format(repoUrl))

  if osp.isdir(d):
    logging.info("using existing {} ".format(d))
    r = git.Repo(d)
    o = r.remote('origin')
    o.fetch()
  else:
    logging.info("cloning from remote into {} ".format(d))
    r = git.Repo.clone_from(repoUrl, d)
    o = r.remote('origin')

  return r, o

def findMostRecentTag(repo, tagType):
  tags = [ t for t in repo.tags if t.name.find(tagType) > 0 ]
  tags = sorted(tags, key = lambda x: x.name)
  logging.info("found tags: {}".format(tags))
  if not tags:
    logging.error("no tags found, aborting")
    sys.exit(2)
  old = tags[0]
  logging.info("most recent tag: {}".format(old.name))
  return old

def listCommits(repo, old, new):
  sl = "{}...{}".format(old.name, new)
  logging.info("running git log {}".format(sl))
  yield from repo.iter_commits(sl)

def filterCommit(commit):
  tickets = JIRA_FILTER.findall(commit.message)
  cl = CHANGELOG_FILTER.findall(commit.summary)
  if tickets or cl:
    # only attach those tickets that are not directly mentioned in
    # the subject
    tickets = [ t for t in tickets if commit.summary.find(t) < 0 ]
    return commit, tickets
  else:
    return None, None

def sortCommitListByDateAuthored(l):
  return sorted(l, key = lambda x: x[0].authored_date)

def formatCommitList(l, sep = '\n'):
  return sep.join([formatCommit(*x) for x in l])

## main
args = parser.parse_args()

# logging
logging.getLogger().setLevel(getattr(logging, args.logLevel.upper()))
console = logging.StreamHandler(sys.stderr)
formatter = logging.Formatter('[%(asctime)s] changelog: %(levelname)-7s %(message)s')
console.setFormatter(formatter)
logging.getLogger('').addHandler(console)

# go
logging.info("started with {}".format(" ".join(sys.argv[1:])))

# derive remote branch name from version
majorMinor = '.'.join(args.version.split(".")[0:2]) # FIXME
new = BRANCH_TPL.format(majorMinor)

# to store final results
changelogCommits = []
allCommits = []

# create tag name and message anyway
tagName = generateTag(args.version, args.tagType)
tagMsg = "Automated tag creation: version={}, branch={}".format(args.version, new)

# create tmp dir
if not osp.isdir(BASE_DIR):
  os.makedirs(BASE_DIR)

# iterate over repositories
for name in REPOSITORIES:
  repo, origin = updateRepo(name)

  old = findMostRecentTag(repo, args.tagType)

  for commit in listCommits(repo, old, new):
    logging.info(" {}".format(formatCommit(commit, name)))
    allCommits.append((commit, name, None))
    
    clCommit, tickets = filterCommit(commit)
    if clCommit:
      changelogCommits.append((commit, name, tickets))

  if args.createTags:
    logging.info("about to create tag {}".format(tagName))
    t = repo.create_tag(tagName, ref=new, message=tagMsg)
    origin.push(t)

allCommits = sortCommitListByDateAuthored(allCommits)
changelogCommits = sortCommitListByDateAuthored(changelogCommits)

logging.info("all commits:\n  {}".format(formatCommitList(allCommits,"\n  ")))
logging.info("done")

print(formatCommitList(changelogCommits))
