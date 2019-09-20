# Opspresso Builder

## Usage

```yaml
name: GitHub Release

on: push

jobs:
  builder:
    runs-on: ubuntu-latest
    steps:
    - uses: actions/checkout@master

    - uses: opspresso/action-builder@master
      with:
        args: publish
      env:
        AWS_ACCESS_KEY_ID: ${{ secrets.AWS_ACCESS_KEY_ID }}
        AWS_SECRET_ACCESS_KEY: ${{ secrets.AWS_SECRET_ACCESS_KEY }}
        AWS_REGION: "us-east-1"
        FROM_PATH: "./target/publish"
        DEST_PATH: "s3://your_bucket_name/path/"
        OPTIONS: "--acl public-read"

    - uses: opspresso/action-builder@master
      with:
        args: release
      env:
        GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}
        TAG_NAME: "v0.0.1"

    - uses: opspresso/action-builder@master
      with:
        args: slack
      env:
        SLACK_TOKEN: ${{ secrets.SLACK_TOKEN }}
        JSON_PATH: ./target/slack_message.json
```

## env

Name | Description | Default | Required
---- | ----------- | ------- | --------
GITHUB_TOKEN | Your GitHub Token. | | **Yes**
TAG_NAME | The name of the tag. | $(cat ./target/TAG_NAME) | No
TARGET_COMMITISH | Specifies the commitish value that determines where the Git tag is created from. | master | No
NAME | The name of the release. | | No
BODY | Text describing the contents of the tag. | | No
DRAFT | `true` to create a draft (unpublished) release, `false` to create a published one. | false | No
PRERELEASE | `true` to identify the release as a prerelease. `false` to identify the release as a full release. | false | No
ASSET_PATH | The path where the release asset files. | | No
