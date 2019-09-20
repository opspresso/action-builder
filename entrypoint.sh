#!/bin/bash

CMD="$1"

if [ -z "${CMD}" ]; then
  exit 0
fi

echo "[${CMD}] start..."

_error() {
  echo -e "$1"

  if [ ! -z "${LOOSE_ERROR}" ]; then
    exit 0
  else
    exit 1
  fi
}

_version() {
  if [ ! -f ./VERSION ]; then
    printf "v0.0.x" > ./VERSION
  fi

  echo "GITHUB_REF: ${GITHUB_REF}"

  # release version
  MAJOR=$(cat ./VERSION | xargs | cut -d'.' -f1)
  MINOR=$(cat ./VERSION | xargs | cut -d'.' -f2)
  PATCH=$(cat ./VERSION | xargs | cut -d'.' -f3)

  if [ "${PATCH}" != "x" ]; then
    VERSION="${MAJOR}.${MINOR}.${PATCH}"
    printf "${VERSION}" > ./VERSION
  else
    # latest versions
    URL="https://api.github.com/repos/${GITHUB_REPOSITORY}/releases"
    VERSION=$(curl -s ${URL} | jq -r '.[] | .tag_name' | grep "${MAJOR}.${MINOR}." | cut -d'-' -f1 | sort -Vr | head -1)

    if [ -z ${VERSION} ]; then
      VERSION="${MAJOR}.${MINOR}.0"
    fi

    echo "VERSION: ${VERSION}"

    # new version
    if [ "${GITHUB_REF}" == "refs/heads/master" ]; then
      VERSION=$(echo ${VERSION} | perl -pe 's/^(([v\d]+\.)*)(\d+)(.*)$/$1.($3+1).$4/e')
    else
      if [ "${GITHUB_REF}" != "" ]; then
        # refs/pull/1/merge
        PR_CMD=$(echo "${GITHUB_REF}" | cut -d'/' -f2)
        PR_NUM=$(echo "${GITHUB_REF}" | cut -d'/' -f3)
      fi

      if [ "${PR_CMD}" == "pull" ] && [ "${PR_NUM}" != "" ]; then
        VERSION="${VERSION}-${PR_NUM}"
      else
        VERSION=""
      fi
    fi

    if [ "${VERSION}" != "" ]; then
      printf "${VERSION}" > ./VERSION
    fi
  fi

  echo "VERSION: ${VERSION}"
}

_commit_pre() {
  if [ -z "${GITHUB_TOKEN}" ]; then
    _error "GITHUB_TOKEN is not set."
  fi

  if [ -z "${GIT_USERNAME}" ]; then
    GIT_USERNAME="bot"
  fi

  if [ -z "${GIT_USEREMAIL}" ]; then
    GIT_USEREMAIL="bot@nalbam.com"
  fi

  if [ -z "${GIT_BRANCH}" ]; then
    GIT_BRANCH="master"
  fi
}

_commit() {
  _commit_pre

  # git init

  git config --global user.name "${GIT_USERNAME}"
  git config --global user.email "${GIT_USEREMAIL}"

  git branch -a -v

  echo "git add --all"
  git add --all

  echo "git commit -m ${MESSAGE}"
  git commit -a --allow-empty-message -m "${MESSAGE}"

  echo "git remote add builder github.com/${GITHUB_REPOSITORY}"
  git remote add builder https://${GITHUB_TOKEN}@github.com/${GITHUB_REPOSITORY}.git

  echo "git push -u builder ${GIT_BRANCH}"
  git push -u builder ${GIT_BRANCH}

  # echo "git push github.com/${GITHUB_REPOSITORY} ${GIT_BRANCH}"
  # git push -q https://${GITHUB_TOKEN}@github.com/${GITHUB_REPOSITORY}.git ${GIT_BRANCH}
}

_publish_pre() {
  if [ -z "${AWS_ACCESS_KEY_ID}" ]; then
    _error "AWS_ACCESS_KEY_ID is not set."
  fi

  if [ -z "${AWS_SECRET_ACCESS_KEY}" ]; then
    _error "AWS_SECRET_ACCESS_KEY is not set."
  fi

  if [ -z "${AWS_REGION}" ]; then
    AWS_REGION="us-east-1"
  fi

  if [ -z "${FROM_PATH}" ]; then
    FROM_PATH="."
  fi

  if [ -z "${DEST_PATH}" ]; then
    _error "DEST_PATH is not set."
  fi
}

_publish() {
  _publish_pre

  aws configure <<-EOF > /dev/null 2>&1
${AWS_ACCESS_KEY_ID}
${AWS_SECRET_ACCESS_KEY}
${AWS_REGION}
text
EOF

  # aws s3 sync
  echo "aws s3 sync ${FROM_PATH} ${DEST_PATH}"
  aws s3 sync ${FROM_PATH} ${DEST_PATH} ${OPTIONS}

  # s3://bucket/path
  if [ "${DEST_PATH:0:3}" == "s3:" ]; then
    BUCKET="$(echo "${DEST_PATH}" | cut -d'/' -f3)"

    # aws cf reset
    CFID=$(aws cloudfront list-distributions --query "DistributionList.Items[].{Id:Id,Origin:Origins.Items[0].DomainName}[?contains(Origin,'${BUCKET}')] | [0]" | grep 'Id' | cut -d'"' -f4)
    if [ "${CFID}" != "" ]; then
        aws cloudfront create-invalidation --distribution-id ${CFID} --paths "/*"
    fi
  fi
}

_release_pre() {
  if [ -z "${GITHUB_TOKEN}" ]; then
    _error "GITHUB_TOKEN is not set."
  fi

  if [ -z "${TAG_NAME}" ]; then
    if [ -f ./target/TAG_NAME ]; then
      TAG_NAME=$(cat ./target/TAG_NAME | xargs)
    elif [ -f ./target/VERSION ]; then
      TAG_NAME=$(cat ./target/VERSION | xargs)
    elif [ -f ./VERSION ]; then
      TAG_NAME=$(cat ./VERSION | xargs)
    fi
    if [ -z "${TAG_NAME}" ]; then
      _error "TAG_NAME is not set."
    fi
  fi

  if [ -z "${TARGET_COMMITISH}" ]; then
    TARGET_COMMITISH="master"
  fi

  if [ -z "${DRAFT}" ]; then
    DRAFT="false"
  fi

  if [ -z "${PRERELEASE}" ]; then
    PRERELEASE="false"
  fi
}

_release_id() {
  URL="https://api.github.com/repos/${GITHUB_REPOSITORY}/releases"
  RELEASE_ID=$(curl -s ${URL} | TAG_NAME=${TAG_NAME} jq -r '.[] | select(.tag_name == env.TAG_NAME) | .id' | xargs)
  echo "RELEASE_ID: ${RELEASE_ID}"
}

_release_assets() {
  LIST=/tmp/release-list
  ls ${ASSET_PATH} | sort > ${LIST}

  while read FILENAME; do
    FILEPATH=${ASSET_PATH}/${FILENAME}
    FILETYPE=$(file -b --mime-type "${FILEPATH}")
    FILESIZE=$(stat -c%s "${FILEPATH}")

    CONTENT_TYPE_HEADER="Content-Type: ${FILETYPE}"
    CONTENT_LENGTH_HEADER="Content-Length: ${FILESIZE}"

    echo "github releases assets ${RELEASE_ID} ${FILENAME} ${FILETYPE} ${FILESIZE}"
    URL="https://uploads.github.com/repos/${GITHUB_REPOSITORY}/releases/${RELEASE_ID}/assets?name=${FILENAME}"
    curl \
      -sSL \
      -X POST \
      -H "${AUTH_HEADER}" \
      -H "${CONTENT_TYPE_HEADER}" \
      -H "${CONTENT_LENGTH_HEADER}" \
      --data-binary @${FILEPATH} \
      ${URL}
  done < ${LIST}
}

_release() {
  _release_pre

  AUTH_HEADER="Authorization: token ${GITHUB_TOKEN}"

  _release_id
  if [ ! -z "${RELEASE_ID}" ]; then
    echo "github releases delete ${RELEASE_ID}"
    URL="https://api.github.com/repos/${GITHUB_REPOSITORY}/releases/${RELEASE_ID}"
    curl \
      -sSL \
      -X DELETE \
      -H "${AUTH_HEADER}" \
      ${URL}
    sleep 1
  fi

  echo "github releases create ${TAG_NAME} ${DRAFT} ${PRERELEASE}"
  URL="https://api.github.com/repos/${GITHUB_REPOSITORY}/releases"
  curl \
    -sSL \
    -X POST \
    -H "${AUTH_HEADER}" \
    --data @- \
    ${URL} <<END
{
 "tag_name": "${TAG_NAME}",
 "target_commitish": "${TARGET_COMMITISH}",
 "name": "${NAME}",
 "body": "${BODY}",
 "draft": ${DRAFT},
 "prerelease": ${PRERELEASE}
}
END
  sleep 1

  _release_id
  if [ -z "${RELEASE_ID}" ]; then
    _error "RELEASE_ID is not set."
  fi

  if [ ! -z "${ASSET_PATH}" ] && [ -d "${ASSET_PATH}" ]; then
    _release_assets
  fi
}

_docker_pre() {
  if [ -z "${USERNAME}" ]; then
    _error "USERNAME is not set."
  fi

  if [ -z "${PASSWORD}" ]; then
    _error "PASSWORD is not set."
  fi

  if [ -z "${IMAGE_NAME}" ]; then
    _error "IMAGE_NAME is not set."
  fi

  if [ -z "${TAG_NAME}" ]; then
    if [ -f ./target/TAG_NAME ]; then
      TAG_NAME=$(cat ./target/TAG_NAME | xargs)
    elif [ -f ./target/VERSION ]; then
      TAG_NAME=$(cat ./target/VERSION | xargs)
    elif [ -f ./VERSION ]; then
      TAG_NAME=$(cat ./VERSION | xargs)
    fi
    if [ -z "${TAG_NAME}" ]; then
      _error "TAG_NAME is not set."
    fi
  fi
}

_docker() {
  _docker_pre

  echo "docker login -u ${USERNAME}"
  echo ${PASSWORD} | docker login -u ${USERNAME} --password-stdin

  echo "docker build -t ${IMAGE_NAME}:${TAG_NAME} ."
  docker build -t ${IMAGE_NAME}:${TAG_NAME} .

  echo "docker push ${IMAGE_NAME}:${TAG_NAME}"
  docker push ${IMAGE_NAME}:${TAG_NAME}

  if [ ! -z "${LATEST}" ]; then
    echo "docker tag ${IMAGE_NAME}:latest"
    docker tag ${IMAGE_NAME}:${TAG_NAME} ${IMAGE_NAME}:latest

    echo "docker push ${IMAGE_NAME}:latest"
    docker push ${IMAGE_NAME}:latest
  fi

  echo "docker logout"
  docker logout
}

_slack_pre() {
  if [ -z "${SLACK_TOKEN}" ]; then
    _error "SLACK_TOKEN is not set."
  fi

  if [ -z "${JSON_PATH}" ] || [ ! -f "${JSON_PATH}" ]; then
    _error "JSON_PATH is not set."
  fi
}

_slack() {
  _slack_pre

  URL="https://hooks.slack.com/services/${SLACK_TOKEN}"
  curl \
    -sSL \
    -X POST \
    -H "Content-type: application/json" \
    --data @"${JSON_PATH}" \
    ${URL}
}

case "${CMD}" in
  --version|version)
    _version
    ;;
  --commit|commit)
    _commit
    ;;
  --publish|publish)
    _publish
    ;;
  --release|release)
    _release
    ;;
  --docker|docker)
    _docker
    ;;
  --slack|slack)
    _slack
    ;;
esac
