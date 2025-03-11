#!/bin/bash

CMD="$1"

REPOSITORY=${GITHUB_REPOSITORY}

USERNAME=${USERNAME:-$GITHUB_ACTOR}
REPONAME=$(echo "${REPOSITORY}" | cut -d'/' -f2)

command -v tput >/dev/null && TPUT=true

# Function to check if a command is installed
check_command() {
  if ! command -v "$1" &>/dev/null; then
    echo "$1 is not installed. Please install $1 to proceed."
    exit 1
  fi
}

# Check if required commands are installed
check_command jq
check_command curl

_echo() {
  if [ "${TPUT}" != "" ] && [ "$2" != "" ]; then
    echo -e "$(tput setaf $2)$1$(tput sgr0)"
  else
    echo -e "$1"
  fi
}

_result() {
  echo
  _echo "# $@" 4
}

_command() {
  echo
  _echo "$ $@" 3
}

_success() {
  echo
  _echo "+ $@" 2
  exit 0
}

_error() {
  echo
  _echo "- $@" 1
  if [ "${LOOSE_ERROR}" == "true" ]; then
    exit 0
  else
    exit 1
  fi
}

_error_check() {
  RESULT=$?
  if [ ${RESULT} != 0 ]; then
    _error "Command failed with exit code ${RESULT}"
  fi
}

_aws_pre() {
  if [ -z "${AWS_REGION}" ]; then
    AWS_REGION="us-east-1"
  fi

  if [ ! -z "${AWS_ACCESS_KEY_ID}" ] && [ ! -z "${AWS_SECRET_ACCESS_KEY}" ]; then
    # aws credentials
    aws configure <<-EOF >/dev/null 2>&1
${AWS_ACCESS_KEY_ID}
${AWS_SECRET_ACCESS_KEY}
${AWS_REGION}
text
EOF
    _error_check
  fi

  AWS_ACCOUNT_ID="$(aws sts get-caller-identity --output json | jq '.Account' -r)"
  _error_check

  if [ -z "${AWS_ACCOUNT_ID}" ]; then
    _error "AWS_ACCOUNT_ID is not set."
  fi
}

_version() {
  if [ ! -f ./VERSION ]; then
    printf "v0.0.x" >./VERSION
  fi

  _result "GITHUB_REF: ${GITHUB_REF}"

  # release version
  MAJOR=$(cat ./VERSION | xargs | cut -d'.' -f1)
  MINOR=$(cat ./VERSION | xargs | cut -d'.' -f2)
  PATCH=$(cat ./VERSION | xargs | cut -d'.' -f3)

  PRNUM=$(cat ./VERSION | xargs | cut -d'.' -f4)
  if [ "${PRNUM}" == "x" ]; then
    PATCH="x"
  fi

  if [ "${PATCH}" != "x" ]; then
    VERSION="${MAJOR}.${MINOR}.${PATCH}"
    printf "${VERSION}" >./VERSION
  else
    if [ -z "${GITHUB_TOKEN}" ]; then
      URL="https://api.github.com/repos/${GITHUB_REPOSITORY}/releases"
      curl \
        -sSL \
        ${URL} >/tmp/releases
      _error_check
    else
      AUTH_HEADER="Authorization: token ${GITHUB_TOKEN}"
      URL="https://api.github.com/repos/${GITHUB_REPOSITORY}/releases"
      curl \
        -sSL \
        -H "${AUTH_HEADER}" \
        ${URL} >/tmp/releases
      _error_check
    fi

    VERSION=$(cat /tmp/releases | jq -r '.[] | .tag_name' | grep "${MAJOR}.${MINOR}." | cut -d'-' -f1 | sort -Vr | head -1)

    # VERSION=$(git describe --abbrev=0 --tags)

    if [ -z "${VERSION}" ]; then
      VERSION="${MAJOR}.${MINOR}.0"
    fi

    _result "VERSION: ${VERSION}"

    # new version
    if [ "${GITHUB_REF}" == "refs/heads/main" ] || [ "${GITHUB_REF}" == "refs/heads/master" ]; then
      # VERSION=$(echo ${VERSION} | awk -F. '{$NF = $NF + 1;} 1' | sed 's/ /./g')
      VERSION=$(echo ${VERSION} | awk -F. '{if (NF>3) {print $1"."$2"."($3+1)} else {print $1"."$2"."($3+1)}}')
    else
      if [ "${GITHUB_REF}" != "" ]; then
        # refs/pull/1/merge
        PRCMD=$(echo "${GITHUB_REF}" | cut -d'/' -f2)
        PRNUM=$(echo "${GITHUB_REF}" | cut -d'/' -f3)
      fi

      if [ "${PRCMD}" == "pull" ] && [ "${PRNUM}" != "" ]; then
        VERSION="${VERSION}-${PRNUM}"
      else
        VERSION="${VERSION}"
      fi
    fi

    if [ "${VERSION}" != "" ]; then
      printf "${VERSION}" >./VERSION
    fi
  fi

  _result "VERSION: ${VERSION}"

  echo "version=${VERSION}" >>${GITHUB_OUTPUT}
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
    GIT_BRANCH="main"
  fi

  if [ -z "${MESSAGE}" ]; then
    if [ ! -z "${MESSAGE_PATH}" ] && [ -f "${MESSAGE_PATH}" ]; then
      MESSAGE="$(cat ${MESSAGE_PATH})"
    else
      MESSAGE="$(date +%Y%m%d-%H%M)"
    fi
  fi
}

_commit() {
  _commit_pre

  git config --global user.name "${GIT_USERNAME}"
  git config --global user.email "${GIT_USEREMAIL}"

  _command "git checkout ${GIT_BRANCH}"
  git checkout ${GIT_BRANCH}
  _error_check

  _command "git diff"
  git diff
  _error_check

  git diff >/tmp/git_diff.txt
  COUNT=$(cat /tmp/git_diff.txt | wc -l | xargs)

  if [ "x${COUNT}" = "x0" ]; then
    _success "No changes to commit"
  fi

  _command "git add --all"
  git add --all
  _error_check

  _command "git commit -m ${MESSAGE}"
  git commit -a --allow-empty-message -m "${MESSAGE}"
  _error_check

  HEADER=$(echo -n "${GITHUB_ACTOR}:${GITHUB_TOKEN}" | base64)

  _command "git push -u origin ${GIT_BRANCH}"
  git -c http.extraheader="AUTHORIZATION: basic ${HEADER}" push -u origin ${GIT_BRANCH}
  _error_check

  # _command "git push github.com/${GITHUB_REPOSITORY} ${GIT_BRANCH}"
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

  # aws s3 sync
  _command "aws s3 sync ${FROM_PATH} ${DEST_PATH}"
  aws s3 sync ${FROM_PATH} ${DEST_PATH} ${OPTIONS}
  _error_check

  if [ "${CF_RESET}" == "true" ]; then
    # s3://bucket/path
    if [[ "${DEST_PATH:0:5}" == "s3://" ]]; then
      BUCKET="$(echo "${DEST_PATH}" | cut -d'/' -f3)"

      # aws cf reset
      CFID=$(aws cloudfront list-distributions --query "DistributionList.Items[].{Id:Id,Origin:Origins.Items[0].DomainName}[?contains(Origin,'${BUCKET}')] | [0]" | awk '{print $1}')
      if [ "${CFID}" != "" ]; then
        _command "aws cloudfront create-invalidation ${CFID}"
        aws cloudfront create-invalidation --distribution-id ${CFID} --paths "/*"
        _error_check
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
    _result "GITHUB_REF: ${GITHUB_REF}"

    TARGET_COMMITISH="$(echo ${GITHUB_REF} | cut -d'/' -f3)"
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
    ${URL} >/tmp/releases

  RELEASE_ID=$(cat /tmp/releases | TAG_NAME=${TAG_NAME} jq -r '.[] | select(.tag_name == env.TAG_NAME) | .id' | xargs)

  _result "RELEASE_ID: ${RELEASE_ID}"
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

    CNT=$((${CNT} + 1))
  done

  if [ -z "${RELEASE_ID}" ]; then
    _error "RELEASE_ID is not set."
  fi

  echo "release_id=${RELEASE_ID}" >>${GITHUB_OUTPUT}
}

_release_assets() {
  LIST=/tmp/release-list
  ls ${ASSET_PATH} | sort >${LIST}

  while read FILENAME; do
    FILEPATH=${ASSET_PATH}/${FILENAME}
    FILETYPE=$(file -b --mime-type "${FILEPATH}")
    FILESIZE=$(stat -c%s "${FILEPATH}")

    CONTENT_TYPE_HEADER="Content-Type: ${FILETYPE}"
    CONTENT_LENGTH_HEADER="Content-Length: ${FILESIZE}"

    _command "github releases assets ${RELEASE_ID} ${FILENAME} ${FILETYPE} ${FILESIZE}"
    URL="https://uploads.github.com/repos/${GITHUB_REPOSITORY}/releases/${RELEASE_ID}/assets?name=${FILENAME}"
    curl \
      -sSL \
      -X POST \
      -H "${AUTH_HEADER}" \
      -H "${CONTENT_TYPE_HEADER}" \
      -H "${CONTENT_LENGTH_HEADER}" \
      --data-binary @${FILEPATH} \
      ${URL}
  done <${LIST}
}

_release() {
  _release_pre

  AUTH_HEADER="Authorization: token ${GITHUB_TOKEN}"

  _release_id

  if [ ! -z "${RELEASE_ID}" ]; then
    _command "github releases delete ${RELEASE_ID}"
    URL="https://api.github.com/repos/${GITHUB_REPOSITORY}/releases/${RELEASE_ID}"
    curl \
      -sSL \
      -X DELETE \
      -H "${AUTH_HEADER}" \
      ${URL}
    sleep 5
  fi

  _command "github releases create ${TAG_NAME} ${DRAFT} ${PRERELEASE}"
  URL="https://api.github.com/repos/${GITHUB_REPOSITORY}/releases"
  curl \
    -sSL \
    -X POST \
    -H "${AUTH_HEADER}" \
    --data @- \
    ${URL} <<END
{
  "tag_name": "${TAG_NAME}",
  "target_commitish": "${TARGET_COMMITISH:-main}",
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
    EVENT_TYPE="gitops"
  fi

  if [ -z "${PROJECT}" ]; then
    PROJECT="${GITHUB_REPOSITORY}"
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

  _command "github dispatches create ${GITOPS_REPO} ${EVENT_TYPE} ${PROJECT} ${VERSION} ${PHASE} ${CONTAINER} ${ACTION}"

  curl -sL -X POST \
    -H "Accept: application/vnd.github.v3+json" \
    -H "Authorization: Bearer ${GITHUB_TOKEN}" \
    -d "{\"event_type\":\"${EVENT_TYPE}\",\"client_payload\":{\"username\":\"${USERNAME}\",\"project\":\"${PROJECT}\",\"version\":\"${VERSION}\",\"phase\":\"${PHASE}\",\"container\":\"${CONTAINER}\",\"action\":\"${ACTION}\"}}" \
    https://api.github.com/repos/${GITOPS_REPO}/dispatches
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

_docker_build() {
  _command "docker build ${DOCKER_BUILD_ARGS} -t ${IMAGE_URI}:${TAG_NAME} -f ${DOCKERFILE} ${BUILD_PATH}"
  docker build ${DOCKER_BUILD_ARGS} -t ${IMAGE_URI}:${TAG_NAME} -f ${DOCKERFILE} ${BUILD_PATH}

  _error_check

  _command "docker push ${IMAGE_URI}:${TAG_NAME}"
  docker push ${IMAGE_URI}:${TAG_NAME}

  _error_check

  if [ "${LATEST}" == "true" ]; then
    _command "docker tag ${IMAGE_URI}:latest"
    docker tag ${IMAGE_URI}:${TAG_NAME} ${IMAGE_URI}:latest

    _command "docker push ${IMAGE_URI}:latest"
    docker push ${IMAGE_URI}:latest
  fi
}

# _docker_builds() {
#   TAG_NAMES=""

#   ARR=(${PLATFORM//,/ })

#   for V in ${ARR[@]}; do
#       P="${V//\//-}"

#       _command "docker build ${DOCKER_BUILD_ARGS} --build-arg ARCH=${V} -t ${IMAGE_URI}:${TAG_NAME}-${P} -f ${DOCKERFILE} ${BUILD_PATH}"
#       docker build ${DOCKER_BUILD_ARGS} --build-arg ARCH=${V} -t ${IMAGE_URI}:${TAG_NAME}-${P} -f ${DOCKERFILE} ${BUILD_PATH}

#       _error_check

#       _command "docker push ${IMAGE_URI}:${TAG_NAME}-${P}"
#       docker push ${IMAGE_URI}:${TAG_NAME}-${P}

#       _error_check

#       TAG_NAMES="${TAG_NAMES} -a ${IMAGE_URI}:${TAG_NAME}-${P}"
#   done

#   _docker_manifest ${IMAGE_URI}:${TAG_NAME} ${TAG_NAMES}

#   # if [ "${LATEST}" == "true" ]; then
#   #   _docker_manifest ${IMAGE_URI}:latest -a ${TAG_NAMES}
#   # fi
# }

# _docker_manifest() {
#   _command "docker manifest create ${@}"
#   docker manifest create ${@}

#   _error_check

#   _command "docker manifest inspect ${1}"
#   docker manifest inspect ${1}

#   _command "docker manifest push ${1}"
#   docker manifest push ${1}
# }

_docker_buildx() {
  if [ -z "${PLATFORM}" ]; then
    PLATFORM="linux/arm64,linux/amd64"
  fi

  PLACE=$(date +%s)

  _command "docker buildx create --use --name ops-${PLACE}"
  docker buildx create --use --name ops-${PLACE}

  _command "docker buildx build ${DOCKER_BUILD_ARGS} -t ${IMAGE_URI}:${TAG_NAME} -f ${DOCKERFILE} ${BUILD_PATH}"
  docker buildx build --push ${DOCKER_BUILD_ARGS} -t ${IMAGE_URI}:${TAG_NAME} -f ${DOCKERFILE} ${BUILD_PATH} --platform ${PLATFORM}

  _error_check

  _command "docker buildx imagetools inspect ${IMAGE_URI}:${TAG_NAME}"
  docker buildx imagetools inspect ${IMAGE_URI}:${TAG_NAME}

  # if [ "${LATEST}" == "true" ]; then
  #   _docker_manifest ${IMAGE_URI}:latest -a ${IMAGE_URI}:${TAG_NAME}
  # fi
}

_docker_pre() {
  if [ -z "${USERNAME}" ]; then
    _error "USERNAME is not set."
  fi

  if [ -z "${PASSWORD}" ]; then
    _error "PASSWORD is not set."
  fi

  BUILD_PATH="${BUILD_PATH:-.}"
  DOCKERFILE="${DOCKERFILE:-Dockerfile}"

  if [ -z "${IMAGE_NAME}" ]; then
    if [ "${REGISTRY}" == "docker.pkg.github.com" ]; then
      IMAGE_NAME="${REPONAME}"
    else
      IMAGE_NAME="${REPOSITORY}"
    fi
  fi

  if [ -z "${IMAGE_URI}" ]; then
    if [ -z "${REGISTRY}" ]; then
      IMAGE_URI="${IMAGE_NAME}"
    elif [ "${REGISTRY}" == "docker.pkg.github.com" ]; then
      # :owner/:repo_name/:image_name
      IMAGE_URI="${REGISTRY}/${REPOSITORY}/${IMAGE_NAME}"
    else
      IMAGE_URI="${REGISTRY}/${IMAGE_NAME}"
    fi
  fi

  _docker_tag
}

_docker() {
  _docker_pre

  _command "docker login ${REGISTRY} -u ${USERNAME}"
  echo ${PASSWORD} | docker login ${REGISTRY} -u ${USERNAME} --password-stdin

  _error_check

  if [ "${BUILDX}" == "true" ]; then
    _docker_buildx
  else
    _docker_build
    # if [ "${PLATFORM}" == "" ]; then
    #   _docker_build
    # else
    #   _docker_builds
    # fi
  fi

  _command "docker logout"
  docker logout
}

_docker_ecr_pre() {
  _aws_pre

  if [ -z "${BUILD_PATH}" ]; then
    BUILD_PATH="."
  fi

  if [ -z "${DOCKERFILE}" ]; then
    DOCKERFILE="Dockerfile"
  fi

  if [ -z "${REGISTRY}" ]; then
    REGISTRY="${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"
  fi

  PUBLIC=$(echo ${REGISTRY} | cut -d'.' -f1)

  if [ -z "${IMAGE_NAME}" ]; then
    if [ "${PUBLIC}" == "public" ]; then
      IMAGE_NAME="${REPONAME}"
    else
      IMAGE_NAME="${REPOSITORY}"
    fi
  fi

  if [ -z "${IMAGE_URI}" ]; then
    IMAGE_URI="${REGISTRY}/${IMAGE_NAME}"
  fi

  _docker_tag

  if [ "${IMAGE_TAG_MUTABILITY}" != "IMMUTABLE" ]; then
    IMAGE_TAG_MUTABILITY="MUTABLE"
  fi
}

_docker_ecr() {
  _docker_ecr_pre

  if [ "${PUBLIC}" == "public" ]; then
    _command "aws ecr-public get-login-password --region us-east-1 ${REGISTRY}"
    aws ecr-public get-login-password --region us-east-1 | docker login --username AWS --password-stdin ${REGISTRY}
  else
    _command "aws ecr get-login-password --region ${AWS_REGION} ${REGISTRY}"
    aws ecr get-login-password --region ${AWS_REGION} | docker login --username AWS --password-stdin ${REGISTRY}
  fi

  _error_check

  if [ "${PUBLIC}" == "public" ]; then
    COUNT=$(aws ecr-public describe-repositories --region us-east-1 --output json | jq '.repositories[] | .repositoryName' | grep "\"${IMAGE_NAME}\"" | wc -l | xargs)
    if [ "x${COUNT}" == "x0" ]; then
      _command "aws ecr-public create-repository ${IMAGE_NAME}"
      aws ecr-public create-repository --repository-name ${IMAGE_NAME} --region us-east-1
    fi
  else
    COUNT=$(aws ecr describe-repositories --output json | jq '.repositories[] | .repositoryName' | grep "\"${IMAGE_NAME}\"" | wc -l | xargs)
    if [ "x${COUNT}" == "x0" ]; then
      _command "aws ecr create-repository ${IMAGE_NAME}"
      aws ecr create-repository --repository-name ${IMAGE_NAME} --image-tag-mutability ${IMAGE_TAG_MUTABILITY}
    fi
  fi

  if [ "${BUILDX}" == "true" ]; then
    _docker_buildx
  else
    _docker_build
    # if [ "${PLATFORM}" == "" ]; then
    #   _docker_build
    # else
    #   _docker_builds
    # fi
  fi
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

_result "[${CMD:2}] start..."

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
  ;;
esac
