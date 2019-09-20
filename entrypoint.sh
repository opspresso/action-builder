#!/bin/bash

CMD="$1"

if [ -z "${CMD}" ]; then
  exit 0
fi

echo "[${CMD}] start..."

_prepare() {
  # mkdir -p target

  if [ ! -d ./target ]; then
    echo "./target is not directory."
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
        printf "${VERSION}" > ./target/VERSION
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
                # printf "${PR_NUM}" > ./target/PR
            else
                VERSION=""
            fi
        fi

        if [ "${VERSION}" != "" ]; then
            printf "${VERSION}" > ./target/VERSION
        fi
    fi

    echo "VERSION: ${VERSION}"
}

_publish_pre() {
  if [ -z "${AWS_ACCESS_KEY_ID}" ]; then
    echo "AWS_ACCESS_KEY_ID is not set."
    exit 1
  fi

  if [ -z "${AWS_SECRET_ACCESS_KEY}" ]; then
    echo "AWS_SECRET_ACCESS_KEY is not set."
    exit 1
  fi

  if [ -z "${AWS_REGION}" ]; then
    AWS_REGION="us-east-1"
  fi

  if [ -z "${FROM_PATH}" ]; then
    FROM_PATH="."
  fi

  if [ -z "${DEST_PATH}" ]; then
    echo "DEST_PATH is not set."
    exit 1
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

  aws s3 sync ${FROM_PATH} ${DEST_PATH} ${OPTIONS}
}

_release_pre() {
  if [ -z "${GITHUB_TOKEN}" ]; then
    echo "GITHUB_TOKEN is not set."
    exit 1
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
      echo "TAG_NAME is not set."
      exit 1
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
    echo "RELEASE_ID is not set."
    exit 1
  fi

  if [ ! -z "${ASSET_PATH}" ] && [ -d "${ASSET_PATH}" ]; then
    _release_assets
  fi
}

_slack_pre() {
  if [ -z "${SLACK_TOKEN}" ]; then
    echo "SLACK_TOKEN is not set."
    exit 1
  fi

  if [ -z "${JSON_PATH}" ] || [ ! -f "${JSON_PATH}" ]; then
    echo "JSON_PATH is not set."
    exit 1
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

_prepare

case "${CMD}" in
  --version|version)
    _version
    ;;
  --publish|publish)
    _publish
    ;;
  --release|release)
    _release
    ;;
  --slack|slack)
    _slack
    ;;
esac
