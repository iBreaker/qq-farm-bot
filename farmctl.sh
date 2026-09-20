#!/usr/bin/env bash
set -Eeuo pipefail

# QQ 农场本地运维入口。默认操作账号 2，可用 QQ_FARM_ACCOUNT_ID 覆盖。
BASE_URL="${QQ_FARM_BASE_URL:-http://127.0.0.1:3007}"
ACCOUNT_ID="${QQ_FARM_ACCOUNT_ID:-1}"
ADMIN_USERNAME="${QQ_FARM_ADMIN_USERNAME:-admin}"
ADMIN_TOKEN="${QQ_FARM_ADMIN_TOKEN:-}"
ADMIN_PASSWORD="${QQ_FARM_ADMIN_PASSWORD:-}"

die() {
    echo "farmctl: $*" >&2
    exit 1
}

usage() {
    cat <<'EOF'
用法：
  ./farmctl.sh status                         查看账号、土地、种子和化肥摘要
  ./farmctl.sh farm [all|harvest|clear|plant] [土地编号]
  ./farmctl.sh fertilize <土地编号> <normal|organic>
  ./farmctl.sh pet                            查看萌宠日记摘要
  ./farmctl.sh claim-seeds                    领取可用的每日活动种子
  ./farmctl.sh feed [次数]                    投喂比熊，默认 1 次
  ./farmctl.sh story <手记编号>               领取已解锁的手记奖励

认证：优先使用 QQ_FARM_ADMIN_TOKEN；否则使用 QQ_FARM_ADMIN_PASSWORD，
未设置密码且终端可交互时会安全提示输入。账号默认是 2。
EOF
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || die "缺少命令：$1"
}

login() {
    if [[ -n "$ADMIN_TOKEN" ]]; then
        if curl -fsS "$BASE_URL/api/auth/validate" \
            -H "x-admin-token: $ADMIN_TOKEN" >/dev/null 2>&1; then
            return
        fi
        ADMIN_TOKEN=""
    fi

    if [[ -z "$ADMIN_PASSWORD" ]]; then
        [[ -t 0 ]] || die "请设置 QQ_FARM_ADMIN_PASSWORD 或 QQ_FARM_ADMIN_TOKEN"
        read -r -s -p "管理员密码：" ADMIN_PASSWORD
        echo
    fi

    local login_payload login_response
    login_payload="$(jq -n --arg username "$ADMIN_USERNAME" --arg password "$ADMIN_PASSWORD" \
        '{username:$username,password:$password}')"
    login_response="$(curl -fsS -X POST "$BASE_URL/api/login" \
        -H 'Content-Type: application/json' --data "$login_payload")" \
        || die "管理员登录失败"
    ADMIN_TOKEN="$(printf '%s' "$login_response" | jq -r '.data.token // empty')"
    [[ -n "$ADMIN_TOKEN" ]] || die "管理员登录未返回 token"
}

api_get() {
    curl -fsS "$BASE_URL$1" \
        -H "x-admin-token: $ADMIN_TOKEN" \
        -H "x-account-id: $ACCOUNT_ID"
}

api_post() {
    curl -fsS -X POST "$BASE_URL$1" \
        -H "x-admin-token: $ADMIN_TOKEN" \
        -H "x-account-id: $ACCOUNT_ID" \
        -H 'Content-Type: application/json' \
        --data "$2"
}

print_result() {
    jq 'if .ok then {ok, data: (.data | if type == "object" then del(.snapshot) else . end)} else {ok,error,errorCode} end'
}

show_status() {
    local status_json lands_json bag_json
    status_json="$(api_get '/api/status')"
    lands_json="$(api_get '/api/lands')"
    bag_json="$(api_get '/api/bag')"

    jq -n \
        --argjson status "$status_json" \
        --argjson lands "$lands_json" \
        --argjson bag "$bag_json" '
        {
          account: ($status.data.status | {
            name, platform, level, exp, gold, coupon, goldBean
          }),
          lands: $lands.data.summary,
          crops: (
            [$lands.data.lands[]
              | select(.status != "locked")
              | {masterLandId, plantName, status, matureInSec}]
            | unique_by(.masterLandId)
            | group_by(.plantName)
            | map({name: .[0].plantName, count: length})
          ),
          activitySeeds: [
            $bag.data.items[]
            | select(.id == 29004 or .id == 25995 or .id == 20516)
            | {id, name, count}
          ],
          fertilizers: [
            $bag.data.systemItems[]
            | select(.id == 1011 or .id == 1012)
            | {id, name, hoursText, seconds: .count}
          ]
        }'
}

show_pet() {
    api_get '/api/activity-center/pet-diary' | jq '
      if .ok then
        .data | {
          active,
          cake: ([.balances[] | select(.id == "1028")][0].count // "0"),
          luckyStar: ([.balances[] | select(.id == "1029")][0].count // "0"),
          nurture: (.nurture | {adult, growth, adultGrowth, feedCount, feedLimit, canFeed}),
          seeds: {
            canClaim: .seeds.canClaim,
            claimableDays: [.seeds.days[] | select(.claimable and (.claimed | not)) | .day]
          },
          unclaimedStories: [.stories[] | select(.unlocked and (.claimed | not)) | .order]
        }
      else {ok,error,errorCode}
      end'
}

require_command curl
require_command jq

command_name="${1:-}"
[[ -n "$command_name" ]] || { usage; exit 1; }
shift

case "$command_name" in
    -h|--help|help)
        usage
        exit 0
        ;;
esac

login

case "$command_name" in
    status)
        [[ $# -eq 0 ]] || die "status 不接受参数"
        show_status
        ;;
    farm)
        op_type="${1:-all}"
        land_id="${2:-}"
        case "$op_type" in all|harvest|clear|plant) ;; *) die "不支持的务农操作：$op_type" ;; esac
        if [[ -n "$land_id" ]]; then
            [[ "$land_id" =~ ^[1-9][0-9]*$ ]] || die "土地编号必须是正整数"
            payload="$(jq -n --arg opType "$op_type" --argjson landId "$land_id" '{opType:$opType,landId:$landId}')"
        else
            payload="$(jq -n --arg opType "$op_type" '{opType:$opType,landId:null}')"
        fi
        api_post '/api/farm/operate' "$payload" | print_result
        ;;
    fertilize)
        land_id="${1:-}"
        fertilizer_type="${2:-}"
        [[ "$land_id" =~ ^[0-9]+$ ]] || die "土地编号必须是正整数"
        case "$fertilizer_type" in normal|organic) ;; *) die "化肥类型必须是 normal 或 organic" ;; esac
        payload="$(jq -n --argjson landId "$land_id" --arg fertilizerType "$fertilizer_type" \
            '{landId:$landId,fertilizerType:$fertilizerType}')"
        api_post '/api/farm/fertilize' "$payload" | print_result
        ;;
    pet)
        [[ $# -eq 0 ]] || die "pet 不接受参数"
        show_pet
        ;;
    claim-seeds)
        [[ $# -eq 0 ]] || die "claim-seeds 不接受参数"
        api_post '/api/activity-center/pet-diary/operate' '{"action":"seeds","params":{}}' | print_result
        ;;
    feed)
        feed_count="${1:-1}"
        [[ "$feed_count" =~ ^[1-9][0-9]*$ ]] || die "投喂次数必须是正整数"
        [[ "$feed_count" -le 16 ]] || die "单次最多执行 16 次投喂"
        for ((i = 1; i <= feed_count; i++)); do
            echo "投喂 $i/$feed_count"
            api_post '/api/activity-center/pet-diary/operate' '{"action":"feed","params":{}}' \
                | jq '{ok,error,rewards:.data.rewards,costs:.data.costs,nurture:(.data.snapshot.nurture|{growth,adultGrowth,feedCount,canFeed})}'
        done
        ;;
    story)
        story_order="${1:-}"
        [[ "$story_order" =~ ^[1-9][0-9]*$ ]] || die "手记编号必须是正整数"
        payload="$(jq -n --argjson order "$story_order" '{action:"story",params:{order:$order}}')"
        api_post '/api/activity-center/pet-diary/operate' "$payload" | print_result
        ;;
    *)
        usage >&2
        die "未知命令：$command_name"
        ;;
esac
