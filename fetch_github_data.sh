#!/bin/bash

set -eu -o pipefail

DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"

MAX_ALL_PR_PAGES=600
COMMIT_PR_SAMPLESIZE=200
PR_SAMPLESIZE=250
MAX_SPAN_DAYS=7300

ORIGIN_REMOTE="origin"
ORIGIN_URL="$(git config --get-regex remote.${ORIGIN_REMOTE}.url | gawk '{print $2}')" || true
REPO=$(echo "$ORIGIN_URL" | sed 's/\.git$//' | sed -E '/^(git@|https:\/\/([^:@/]*(:[^:@]*)?@)?)github.com[:\/]/!{q1}; {s/.*github.com[:\/]([^\/]*\/[^\]*)$/\1/}')

#TODO: sampling on what we're pulling from github
#   for instance, we could grab the most recent K PRs (or limit to closed PRs)
echo "now we'll get some data from github. this might take a while."
echo "fetching pull request and issue data..."
starttime=$(date +%s)
echo 'https://api.github.com/repos/'${REPO}'/languages' | GITHUB_TOKEN=$GITHUB_TOKEN ${DIR}/fetch-comments.sh > ${DATADIR}/languages.json
echo 'https://api.github.com/repos/'${REPO}'/pulls?state=all&sort=created&direction=desc&per_page=100' | GITHUB_TOKEN=$GITHUB_TOKEN MAX_PAGES=${MAX_ALL_PR_PAGES} ALLCOMMENTS="" ${DIR}/fetch-comments.sh | gzip -c > ${DATADIR}/pulls.gz

EARLIEST_PR=$(zcat ${DATADIR}/pulls.gz | jq -r '.[] | .created_at' | sort -r | tail -n1)
LATEST_PR=$(zcat ${DATADIR}/pulls.gz | jq -r '.[] | .updated_at' | sort | tail -n1)
LATEST_COMMIT=$(date -d@$(cat ${DATADIR}/commitdates | cut -f 2 | sort -n | tail -n1) --utc +%Y-%m-%dT%H:%M:%SZ)

#tried using the latest of commit and PR, but commit makes more sense
#for some inactive repos PRs might still get comments long after the last commit
#LATEST_DATE=$(printf "%s\n%s\n" "${LATEST_PR}" "${LATEST_COMMIT}" | gawk '$1 > max_date { max_date = $1 } END {print max_date}')
LATEST_DATE=$LATEST_COMMIT
MAX_SPAN_DATE=$(date -d@$(( $(date -d "$LATEST_DATE" +%s) - $(( $MAX_SPAN_DAYS * 86400 )) )) --utc +%Y-%m-%dT%H:%M:%SZ)

printf "EARLIEST_PR\t%d\n" $(date -d $EARLIEST_PR +%s) >> ${DATADIR}/times.tsv
printf "LATEST_PR\t%d\n" $(date -d $LATEST_PR +%s) >> ${DATADIR}/times.tsv
printf "LATEST_COMMIT\t%d\n" $(date -d $LATEST_COMMIT +%s) >> ${DATADIR}/times.tsv
printf "MAX_SPAN_DATE\t%d\n" $(date -d $MAX_SPAN_DATE +%s) >> ${DATADIR}/times.tsv

#limit to max span of analysis
EARLIEST_DATE=$EARLIEST_PR
if [[ "$EARLIEST_DATE" < "$MAX_SPAN_DATE" ]]; then
    EARLIEST_DATE=$MAX_SPAN_DATE
fi
EARLIEST_DATE="2021-03-01T00:00:00Z"

# if ! (echo 'https://api.github.com/repos/'${REPO}'/pulls/comments?since='${EARLIEST_DATE}'&sort=created&direction=desc&per_page=100' | GITHUB_TOKEN=$GITHUB_TOKEN ALLCOMMENTS="" ${DIR}/fetch-comments.sh | gzip -c > ${DATADIR}/pull-comments.gz); then
#     zcat ${DATADIR}/pulls.gz | jq -r '.[] | .review_comments_url' | sed 's/$/?per_page=100/' | GITHUB_TOKEN=$GITHUB_TOKEN ALLCOMMENTS="" SILENT=true ${DIR}/fetch-comments.sh | pv -l -s $(zcat ${DATADIR}/pulls.gz | jq -r '.[] | .review_comments_url' | wc -l) | gzip -c > ${DATADIR}/pull-comments.gz
# fi

# TODO: issue/comments maxes out at 400 pages
# if you request the 401st page, it'll say:
# "In order to keep the API fast for everyone, pagination is limited for this resource. Check the rel=last link relation in the Link response header to see how far back you can traverse."
# would need an incremental crawler to crawl deeper
# this will get the most recent 400 pages, regardless of their relation to pulls
# if !(echo 'https://api.github.com/repos/'${REPO}'/issues/comments?since='${EARLIEST_DATE}'&sort=created&direction=desc&per_page=100' | GITHUB_TOKEN=$GITHUB_TOKEN ALLCOMMENTS="" ${DIR}/fetch-comments.sh | gzip -c > ${DATADIR}/issue-comments.gz);then
#     zcat ${DATADIR}/pulls.gz | jq -r '.[] | .comments_url' | sed 's/$/?per_page=100/' | GITHUB_TOKEN=$GITHUB_TOKEN ALLCOMMENTS="" SILENT=true ${DIR}/fetch-comments.sh | pv -l -s $(zcat ${DATADIR}/pulls.gz | jq -r '.[] | .comments_url' | wc -l) | gzip -c > ${DATADIR}/issue-comments.gz
fi
#if [ $(zcat ${DATADIR}/issue-comments.gz | zcat | wc -l) -eq 400 ]; then
    #TODO: what to do if we get cut off on comments?
    #A. replace with pull-by-pull and live with not having non-PR comments
    #B. repeatedly recompute latest date and ask for more since then
    #C. compute diff on PRs and fetch missing (maybe handle the edge case?)
    #D. ignore it? maybe measure how often this happens?
#fi
echo 'https://api.github.com/repos/'${REPO}'/issues?since='${EARLIEST_DATE}'&state=all&sort=created&direction=desc&per_page=100' | GITHUB_TOKEN=$GITHUB_TOKEN ALLCOMMENTS="" ${DIR}/fetch-comments.sh | gzip -c > ${DATADIR}/issues.gz
#zcat ${DATADIR}/pulls.gz | jq -r '.[] | .issue_url' | GITHUB_TOKEN=$GITHUB_TOKEN ALLCOMMENTS="" SILENT=true ${DIR}/fetch-comments.sh | pv -l -s $(zcat ${DATADIR}/pulls.gz | jq -r '.[] | .issue_url' | wc -l) | gzip -c > ${DATADIR}/issue.gz

#TODO: we don't use this data anywhere, maybe don't fetch it?
#echo 'https://api.github.com/repos/'${REPO}'/comments?per_page=100' | GITHUB_TOKEN=$GITHUB_TOKEN ALLCOMMENTS="" ${DIR}/fetch-comments.sh | gzip -c > ${DATADIR}/commit-comments.gz

github_fetch_time=$(( $(date +%s) - ${starttime}))
echo "done fetching pull request and issue data in ${github_fetch_time}s."
echo
printf "github_fetch_time\t%f\n" ${github_fetch_time} >> ${DATADIR}/times.tsv

echo "checking with GitHub how a sample of commits relate to pulls..."
starttime=$(date +%s)
cat ${DATADIR}/commitdates |\
    gawk -vrepo=${REPO} -vearliest=$(date -d "${EARLIEST_DATE}" +%s) -F\\t '$2>=earliest {printf("https://api.github.com/repos/%s/commits/%s/pulls\n", repo, $1)}' |\
    sort -R | tail -n${COMMIT_PR_SAMPLESIZE} |\
    GITHUB_TOKEN=$GITHUB_TOKEN HEADER_ACCEPT="application/vnd.github.groot-preview+json" PREFIX_URL=true SILENT=true ${DIR}/fetch-comments.sh | pv -l -s200 \
    > ${DATADIR}/commit_pulls
github_commit_pull_time=$(( $(date +%s) - ${starttime}))
echo "done pulling commit pull request info in ${github_commit_pull_time}s."
echo
printf "github_commit_pull_time\t%f\n" ${github_commit_pull_time} >> ${DATADIR}/times.tsv

if ! (cat ${DATADIR}/pulls.gz | zcat | head -n1 || true) | grep ',    "number": [0-9]*' > /dev/null; then
    echo "there are no PRs in this repository"
    echo

    #just leave the sample files empty
    touch ${DATADIR}/pr_sample
    touch ${DATADIR}/pr_sample_pulls
    touch ${DATADIR}/pr_sample_commits
else
    #get a sample of pulls to prep some additional data
    echo "preparing additional per-PR data for a ${PR_SAMPLESIZE} PR sample of PRs..."

    starttime=$(date +%s)
    echo "drawing the sample..."
    pv ${DATADIR}/pulls.gz | zcat | grep -o ',    "number": [0-9]*' | sed -e 's/.* \([0-9]*\)$/\1/' | sort -R | tail -n${PR_SAMPLESIZE} | LC_ALL=C sort > ${DATADIR}/pr_sample

    echo "fetching full pull objects for PR sample (this might take a while)..."
    cat ${DATADIR}/pr_sample | gawk '{printf("https://api.github.com/repos/'${REPO}'/pulls/%d?per_page=100\n", $1)}' | GITHUB_TOKEN=$GITHUB_TOKEN ALLCOMMENTS="" SILENT=true ${DIR}/fetch-comments.sh | pv -l -s$(cat ${DATADIR}/pr_sample | wc -l) > ${DATADIR}/pr_sample_pulls

    echo "fetch commit list for PR sample (this might take a while)..."
cat ${DATADIR}/pr_sample | gawk '{printf("https://api.github.com/repos/'${REPO}'/pulls/%d/commits?per_page=100\n", $1)}' | GITHUB_TOKEN=$GITHUB_TOKEN ALLCOMMENTS="" SILENT=true PREFIX_URL=true ${DIR}/fetch-comments.sh | pv -l -s$(cat ${DATADIR}/pr_sample | wc -l) > ${DATADIR}/pr_sample_commits

    github_pull_sample_time=$(( $(date +%s) - ${starttime}))
    echo "done collecting sample PR data in ${github_pull_sample_time}s."
    echo
    printf "github_pull_sample_time\t%f\n" ${github_pull_sample_time} >> ${DATADIR}/times.tsv
fi

data_pull_time=$(( $(date +%s) - ${data_pull_start_time} ))
printf "data_pull_time\t%d\n" $data_pull_time >> ${DATADIR}/times.tsv