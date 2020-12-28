#!/bin/bash

CMD="$1"

REPOSITORY=${GITHUB_REPOSITORY}

USERNAME=${USERNAME:-$GITHUB_ACTOR}
REPONAME=$(echo "${REPOSITORY}" | cut -d'/' -f2)

_error() {
  echo -e "$1"

  if [ "${LOOSE_ERROR}" == "true" ]; then
    exit 0
  else
    exit 1
  fi
}

_error_check() {
  RESULT=$?

  if [ ${RESULT} != 0 ]; then
    _error ${RESULT}
  fi
}

_aws_pre() {
  if [ -z "${AWS_ACCESS_KEY_ID}" ]; then
    _error "AWS_ACCESS_KEY_ID is not set."
  fi

  if [ -z "${AWS_SECRET_ACCESS_KEY}" ]; then
    _error "AWS_SECRET_ACCESS_KEY is not set."
  fi

  if [ -z "${AWS_REGION}" ]; then
    AWS_REGION="us-east-1"
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
    if [ "${GITHUB_TOKEN}" != "" ]; then
      AUTH_HEADER="Authorization: token ${GITHUB_TOKEN}"

      URL="https://api.github.com/repos/${GITHUB_REPOSITORY}/releases"
      curl \
        -sSL \
        -H "${AUTH_HEADER}" \
        ${URL} > /tmp/releases
    else
      URL="https://api.github.com/repos/${GITHUB_REPOSITORY}/releases"
      curl \
        -sSL \
        ${URL} > /tmp/releases
    fi

    VERSION=$(cat /tmp/releases | jq -r '.[] | .tag_name' | grep "${MAJOR}.${MINOR}." | cut -d'-' -f1 | sort -Vr | head -1)

    if [ -z ${VERSION} ]; then
      VERSION="${MAJOR}.${MINOR}.0"
    fi

    echo "VERSION: ${VERSION}"

    # new version
    if [ "${GITHUB_REF}" == "refs/heads/master" ]; then
      VERSION=$(echo ${VERSION} | awk -F. '{$NF = $NF + 1;} 1' | sed 's/ /./g')
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

  if [ -z "${MESSAGE}" ]; then
    if [ ! -z "${MESSAGE_PATH}" ] && [ -f "${MESSAGE_PATH}" ]; then
      MESSAGE="$(cat ${MESSAGE_PATH})"
    fi
  fi
}

_commit() {
  _commit_pre

  git config --global user.name "${GIT_USERNAME}"
  git config --global user.email "${GIT_USEREMAIL}"

  echo "git checkout ${GIT_BRANCH}"
  git checkout ${GIT_BRANCH}

  echo "git add --all"
  git add --all

  echo "git commit -m ${MESSAGE}"
  git commit -a --allow-empty-message -m "${MESSAGE}"

  HEADER=$(echo -n "${GITHUB_ACTOR}:${GITHUB_TOKEN}" | base64)

  echo "git push -u origin ${GIT_BRANCH}"
  git -c http.extraheader="AUTHORIZATION: basic ${HEADER}" push -u origin ${GIT_BRANCH}

  # echo "git push github.com/${GITHUB_REPOSITORY} ${GIT_BRANCH}"
  # git push -q https://${GITHUB_TOKEN}@github.com/${GITHUB_REPOSITORY}.git ${GIT_BRANCH}
}

_publish_pre() {
  _aws_pre

  if [ -z "${FROM_PATH}" ]; then
    FROM_PATH="."
  fi

  if [ -z "${DEST_PATH}" ]; then
    # _error "DEST_PATH is not set."
    DEST_PATH="s3://${REPONAME}"
  fi

  if [ -z "${CF_RESET}" ]; then
    CF_RESET="true"
  fi
}

_publish() {
  _publish_pre

  # aws credentials
  aws configure <<-EOF > /dev/null 2>&1
${AWS_ACCESS_KEY_ID}
${AWS_SECRET_ACCESS_KEY}
${AWS_REGION}
text
EOF

  # aws s3 sync
  echo "aws s3 sync ${FROM_PATH} ${DEST_PATH}"
  aws s3 sync ${FROM_PATH} ${DEST_PATH} ${OPTIONS}

  _error_check

  if [ "${CF_RESET}" == "true" ]; then
    # s3://bucket/path
    if [[ "${DEST_PATH:0:5}" == "s3://" ]]; then
      BUCKET="$(echo "${DEST_PATH}" | cut -d'/' -f3)"

      # aws cf reset
      CFID=$(aws cloudfront list-distributions --query "DistributionList.Items[].{Id:Id,Origin:Origins.Items[0].DomainName}[?contains(Origin,'${BUCKET}')] | [0]" | awk '{print $1}')
      if [ "${CFID}" != "" ]; then
          echo "aws cloudfront create-invalidation ${CFID}"
          aws cloudfront create-invalidation --distribution-id ${CFID} --paths "/*"
      fi
    fi
  fi
}

_release_pre() {
  if [ -z "${GITHUB_TOKEN}" ]; then
    _error "GITHUB_TOKEN is not set."
  fi

  if [ ! -z "${TAG_NAME}" ]; then
    TAG_NAME=${TAG_NAME##*/}
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

  if [ ! -z "${TAG_POST}" ]; then
    TAG_NAME="${TAG_NAME}-${TAG_POST}"
  fi

  if [ -z "${TARGET_COMMITISH}" ]; then
    TARGET_COMMITISH="master"
  fi

  if [ "${DRAFT}" != "true" ]; then
    DRAFT="false"
  fi

  if [ "${PRERELEASE}" != "true" ]; then
    PRERELEASE="false"
  fi
}

_release_id() {
  URL="https://api.github.com/repos/${GITHUB_REPOSITORY}/releases"
  curl \
    -sSL \
    -H "${AUTH_HEADER}" \
    ${URL} > /tmp/releases

  RELEASE_ID=$(cat /tmp/releases | TAG_NAME=${TAG_NAME} jq -r '.[] | select(.tag_name == env.TAG_NAME) | .id' | xargs)

  echo "RELEASE_ID: ${RELEASE_ID}"
}

_release_check() {
  REQ=${1:-3}
  CNT=0
  while [ 1 ]; do
    sleep 3

    _release_id

    if [ ! -z "${RELEASE_ID}" ]; then
      break
    elif [ "x${CNT}" == "x${REQ}" ]; then
      break
    fi

    CNT=$(( ${CNT} + 1 ))
  done

  if [ -z "${RELEASE_ID}" ]; then
    _error "RELEASE_ID is not set."
  fi
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
    sleep 5
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

  _release_check

  if [ ! -z "${ASSET_PATH}" ] && [ -d "${ASSET_PATH}" ]; then
    _release_assets
  fi
}

_dispatch_pre() {
  if [ -z "${GITHUB_TOKEN}" ]; then
    _error "GITHUB_TOKEN is not set."
  fi

  if [ -z "${GITOPS_REPO}" ]; then
    _error "GITOPS_REPO is not set."
  fi

  if [ -z "${EVENT_TYPE}" ]; then
    EVENT_TYPE="build"
  fi

  if [ -z "${TARGET_ID}" ]; then
    TARGET_ID="${GITHUB_REPOSITORY}"
  fi

  if [ -z "${VERSION}" ]; then
    if [ -f ./target/VERSION ]; then
      VERSION=$(cat ./target/VERSION | xargs)
    elif [ -f ./VERSION ]; then
      VERSION=$(cat ./VERSION | xargs)
    fi
    if [ -z "${VERSION}" ]; then
      _error "VERSION is not set."
    fi
  fi
}

_dispatch() {
  _dispatch_pre

  AUTH_HEADER="Authorization: token ${GITHUB_TOKEN}"

  ACCEPT_HEADER="Accept: application/vnd.github.v3+json"

  echo "github dispatches create ${GITOPS_REPO} ${EVENT_TYPE} ${TARGET_ID} ${VERSION}"
  URL="https://api.github.com/repos/${GITOPS_REPO}/dispatches"
  curl \
    -sSL \
    -X POST \
    -H "${AUTH_HEADER}" \
    -H "${ACCEPT_HEADER}" \
     --data @- \
    ${URL} <<END
{
  "event_type": "${EVENT_TYPE}"
}
END
}

_docker_tag() {
  if [ ! -z "${TAG_NAME}" ]; then
    TAG_NAME=${TAG_NAME##*/}
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
      TAG_NAME="latest"
    fi
  fi

  if [ ! -z "${TAG_POST}" ]; then
    TAG_NAME="${TAG_NAME}-${TAG_POST}"
  fi
}

_docker_push() {
  echo "docker build ${DOCKER_BUILD_ARGS} -t ${IMAGE_URI}:${TAG_NAME} -f ${DOCKERFILE} ${BUILD_PATH}"
  docker build ${DOCKER_BUILD_ARGS} -t ${IMAGE_URI}:${TAG_NAME} -f ${DOCKERFILE} ${BUILD_PATH}

  _error_check

  echo "docker push ${IMAGE_URI}:${TAG_NAME}"
  docker push ${IMAGE_URI}:${TAG_NAME}

  _error_check

  if [ "${LATEST}" == "true" ]; then
    echo "docker tag ${IMAGE_URI}:latest"
    docker tag ${IMAGE_URI}:${TAG_NAME} ${IMAGE_URI}:latest

    echo "docker push ${IMAGE_URI}:latest"
    docker push ${IMAGE_URI}:latest
  fi
}

_docker_pre() {
  if [ -z "${USERNAME}" ]; then
    _error "USERNAME is not set."
  fi

  if [ -z "${PASSWORD}" ]; then
    _error "PASSWORD is not set."
  fi

  if [ -z "${BUILD_PATH}" ]; then
    BUILD_PATH="."
  fi

  if [ -z "${DOCKERFILE}" ]; then
    DOCKERFILE="Dockerfile"
  fi

  if [ -z "${IMAGE_URI}" ]; then
    if [ -z "${REGISTRY}" ]; then
      IMAGE_URI="${IMAGE_NAME:-${REPOSITORY}}"
    elif [ "${REGISTRY}" == "docker.pkg.github.com" ]; then
      IMAGE_URI="${REGISTRY}/${REPOSITORY}/${IMAGE_NAME:-${REPONAME}}"
    else
      IMAGE_URI="${REGISTRY}/${IMAGE_NAME:-${REPOSITORY}}"
    fi
  fi

  _docker_tag
}

_docker() {
  _docker_pre

  echo "docker login ${REGISTRY} -u ${USERNAME}"
  echo ${PASSWORD} | docker login ${REGISTRY} -u ${USERNAME} --password-stdin

  _error_check

  _docker_push

  echo "docker logout"
  docker logout
}

_docker_ecr_pre() {
  _aws_pre

  if [ -z "${AWS_ACCOUNT_ID}" ]; then
    AWS_ACCOUNT_ID="$(aws sts get-caller-identity --output json | jq '.Account' -r)"
  fi

  if [ -z "${BUILD_PATH}" ]; then
    BUILD_PATH="."
  fi

  if [ -z "${DOCKERFILE}" ]; then
    DOCKERFILE="Dockerfile"
  fi

  if [ -z "${IMAGE_NAME}" ]; then
    IMAGE_NAME="${REPOSITORY}"
  fi

  if [ -z "${IMAGE_URI}" ]; then
    IMAGE_URI="${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com/${IMAGE_NAME}"
  fi

  _docker_tag

  if [ "${IMAGE_TAG_MUTABILITY}" != "IMMUTABLE" ]; then
    IMAGE_TAG_MUTABILITY="MUTABLE"
  fi
}

_docker_ecr() {
  _docker_ecr_pre

  # aws credentials
  aws configure <<-EOF > /dev/null 2>&1
${AWS_ACCESS_KEY_ID}
${AWS_SECRET_ACCESS_KEY}
${AWS_REGION}
text
EOF

  echo "aws ecr get-login --no-include-email"
  aws ecr get-login --no-include-email | sh

  _error_check

  COUNT=$(aws ecr describe-repositories --output json | jq '.repositories[] | .repositoryName' | grep "\"${IMAGE_NAME}\"" | wc -l | xargs)
  if [ "x${COUNT}" == "x0" ]; then
    echo "aws ecr create-repository ${IMAGE_NAME}"
    aws ecr create-repository --repository-name ${IMAGE_NAME} --image-tag-mutability ${IMAGE_TAG_MUTABILITY}
  fi

  _docker_push
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

if [ -z "${CMD}" ]; then
  _error
fi

echo "[${CMD:2}] start..."

case "${CMD:2}" in
  version)
    _version
    ;;
  commit)
    _commit
    ;;
  publish)
    _publish
    ;;
  release)
    _release
    ;;
  dispatch)
    _dispatch
    ;;
  docker)
    _docker
    ;;
  ecr)
    _docker_ecr
    ;;
  slack)
    _slack
    ;;
  *)
    _error
esac
