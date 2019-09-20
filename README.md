# Opspresso Builder

## Usage

```yaml
name: Opspresso Builder

on: push

jobs:
  builder:
    runs-on: ubuntu-latest
    steps:
    - name: Checkout
      uses: actions/checkout@master
      with:
        fetch-depth: 1

    - name: Publish
      uses: opspresso/action-builder@master
      with:
        args: publish
      env:
        AWS_ACCESS_KEY_ID: ${{ secrets.AWS_ACCESS_KEY_ID }}
        AWS_SECRET_ACCESS_KEY: ${{ secrets.AWS_SECRET_ACCESS_KEY }}
        AWS_REGION: "us-east-1"
        FROM_PATH: "./target/publish"
        DEST_PATH: "s3://your_bucket_name/path/"
        OPTIONS: "--acl public-read"

    - name: Release
      uses: opspresso/action-builder@master
      with:
        args: release
      env:
        GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}
        TAG_NAME: "v0.0.1"

    - name: Slack
      uses: opspresso/action-builder@master
      with:
        args: slack
      env:
        SLACK_TOKEN: ${{ secrets.SLACK_TOKEN }}
        JSON_PATH: ./target/slack_message.json
```
