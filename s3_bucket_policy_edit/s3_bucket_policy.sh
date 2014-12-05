#!/bin/sh
# -----------------------------------------------------------------------------
# AWS CLIの確認
#
# retval 0 OK
# retval 1 パスが通っていないのでパスを通した
# retval 2 見つからなかった
# -----------------------------------------------------------------------------
function checkcli() {
    aws --version &> /dev/null
    if [ $? -eq 127 ] ; then
        awspath=$(which aws)
        if [ ! $? -eq 0 ]; then
            echo 'aws-cliが見つかりません'
            exit 2
        else
            addpath=$(echo $awspath |  sed -e 's/aws//g')
            PATH="$PATH":$addpath
            exit 1
        fi
    fi
    exit 0
}
# -----------------------------------------------------------------------------
# 実行しているインスタンス情報の取得
#
# retstd PublicIp 現在処理を行っているインスタンスのPublicIpを返す
# retval 正常終了
# retval 10 インスタンス上で実行されていない
# retval 11 インスタンスのリージョン取得失敗
# -----------------------------------------------------------------------------
function getregion() {
    # メタデータの疎通確認
    curl -s http://169.254.169.254  > /dev/null
    if [ ! $? -eq 0 ] ; then
        echo 'メタ情報にアクセス出来ません。EC2インスタンス上で実行して下さい'
        return 10
    fi
    # インスタンスリージョン取得
    REGION=$(curl -s http://169.254.169.254/latest/meta-data/local-hostname | cut -d '.' -f2)
    if [ -z "${REGION}" ] ; then
        echo 'メタ情報からリージョンの取得に失敗しました'
        return 11
    fi
}

# -----------------------------------------------------------------------------
#
# ヘルプ用書式表示
#
# -----------------------------------------------------------------------------
function syntax() {
    echo "-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-="
    echo "                                                               2014 sato(support by sebastian)"
    echo
    echo " Purpose"
    echo "   指定されたタグのインスタンスのIPをS3バケットポリシー登録に登録します。"
    echo
    echo " Syntax:"
        echo " $0 [-t tagkey] [-r rolename] [-b bucket] "
    echo
    echo "   tagkey: TagKeyを入力"
    echo "   rolename: TagKeyで指定したValueを入力"
    echo "   bucket: ポリシーを変更したいバケット名を入力"
    echo
    echo "-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-="
    exit 0
}

# ----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------
#
# 初期値
#

FILE_S3_BUCKET_POLICY="s3-policy-readonly-stg.json"
BUCKET=""
TAGKEY=""
ROLENAME=""


#
#  引数の処理
#

while [ ! -z "$1" ]; do
    if [ "$1" == "help" ]; then
        syntax
    else
        flag=$1
        shift
        if [ -z "$1" ] ; then
            syntax
        fi
        case $flag in
            '-e' )
                ENV=$1
            ;;
        esac
    fi
    shift
done

if [ -z "${TAGKEY}" ] ; then
    echo "TAGKEYを指定して下さい[-t tagkey]"
    exit 0
fi
if [ -z "${ROLENAME}" ] ; then
    echo "ROLENAMEを指定して下さい[-r rolename]"
    exit 0
fi

if [ -z "${BUCKET}" ] ; then
    echo "BUCKETを指定して下さい[-b bucket]"
    exit 0

#
# AWS CLIの有無
#
check=`checkcli`
result=$?
if [ ! $result -eq 0 ] ; then
    echo $check
    exit $result
fi

#
# リージョンの処理
#
if [ -z "$getregion" ] ; then
    getregion
    result=$?
    if [ ! $result -eq 0 ] ; then
        echo $pip
        exit $result
    fi
fi

#
# 対象環境のIPリスト取得、置換
#
HOSTLIST_TMP=`aws ec2 describe-instances --region ${REGION} --filters "Name=tag-key,Values=${TAGKEY}" "Name=tag-value,Values=${ROLENAME}" | jq '.Reservations[].Instances[].PublicIpAddress'`
if [ ! $? -eq 0 ] ; then
  echo 'PublicIPの取得に失敗しました'
  exit
fi

HOSTLIST=`echo $HOSTLIST_TMP | sed 's/null//g' | sed 's/"  *"/","/g'`

#
# IPリスト確認
#
echo $HOSTLIST
echo "S3に登録するIPはこちらでよろしいですか？ [Y/n]"
read ANSWER

case $ANSWER in
    "" | "Y" | "y" | "yes" | "Yes" | "YES" ) echo "YES!!";;
    * ) exit;;
esac

#
#バケットポリシーのバックアップ
#
DATE=$(date +"%Y%m%d%H%M")
aws s3api get-bucket-policy --bucket ${BUCKET} --region ${REGION} | jq -r '.Policy' | jq .  >  tmp/${FILE_S3_BUCKET_POLICY}_${DATE}.json
if [ ! $? -eq 0 ] ; then
  echo 'ポリシーのバックアップに失敗しました'
  exit
fi

#
# バケットポリシー作成
#
cat << EOF > ${FILE_S3_BUCKET_POLICY}
{
  "Statement": [
    {
      "Condition": {
        "IpAddress": {
          "aws:SourceIp": [${HOSTLIST}]
        }
      },
      "Resource": "arn:aws:s3:::${BUCKET}/*",
      "Action": "s3:GetObject",
      "Principal": {
        "AWS": "*"
      },
      "Effect": "Allow",
      "Sid": "2"
    }
  ],
  "Id": "Policy EC2andCF",
  "Version": "2008-10-17"
}    
EOF

#
# ポリシー出力
#
echo "========================適用予定のポリシー====================================="

cat ${FILE_S3_BUCKET_POLICY} | jq .

echo "============================================================="

echo "========================現在のポリシー====================================="

cat tmp/${FILE_S3_BUCKET_POLICY}_${DATE}.json | jq .

echo "============================================================="A


echo "========================DIFF====================================="

diff -y tmp/${FILE_S3_BUCKET_POLICY}_${DATE}.json  ${FILE_S3_BUCKET_POLICY}

echo "============================================================="

#
# IPリスト確認
#
echo "こちらでよろしいですか？ [Y/n]"
read ANSWER

case $ANSWER in
    "" | "Y" | "y" | "yes" | "Yes" | "YES" ) echo "YES!!";;
    * ) exit;;
esac

#
# バケットポリシー適用
#
aws s3api put-bucket-policy --bucket ${BUCKET} --policy file://${FILE_S3_BUCKET_POLICY} --region ${REGION}
if [ $? -eq 255 ] ; then
    echo "ポリシーの更新に失敗しました"
fi

#
# ポリシー確認
#
aws s3api get-bucket-policy --bucket ${BUCKET} --region ${REGION} | jq -r '.Policy' | jq .
