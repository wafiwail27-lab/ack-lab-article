#!/usr/bin/env bash
# ACK 集群巡检（只读，不修改任何对象）
set -uo pipefail

LOG="/var/log/ack-inspect-$(date +%Y%m%d-%H%M%S).log"
exec > >(tee "$LOG") 2>&1
FAIL=0

hdr(){ echo; echo "===== $1 ====="; }
ok(){ echo "  [ OK ] $*"; }
bad(){ echo "  [FAIL] $*"; FAIL=$((FAIL+1)); }

echo "ACK 巡检  $(date '+%F %T')  主机 $(hostname)"

hdr "1. 节点状态"
kubectl get nodes -o wide
NOTREADY=$(kubectl get nodes --no-headers | awk '$2!="Ready"{print $1}')
if [ -z "$NOTREADY" ]; then ok "全部节点 Ready"; else bad "异常节点: $NOTREADY"; fi

hdr "2. 非 Running 的 Pod（已完成为 Completed 的不算）"
NR=$(kubectl get pods -A --field-selector=status.phase!=Running --no-headers 2>/dev/null | grep -v Completed)
if [ -z "$NR" ]; then ok "无异常 Pod"; else echo "$NR"; bad "存在非 Running Pod"; fi

hdr "3. 重启次数 >= 5 的容器"
R=$(kubectl get pods -A -o jsonpath='{range .items[*]}{.metadata.namespace}{"/"}{.metadata.name}{" "}{range .status.containerStatuses[*]}{.name}{"="}{.restartCount}{" "}{end}{"\n"}{end}' \
    | awk '{for(i=2;i<=NF;i++){split($i,a,"="); if(a[2]>=5) print "  "$1"  "a[1]"  restarts="a[2]}}')
if [ -z "$R" ]; then ok "无高频重启容器"; else echo "$R"; bad "存在高频重启容器"; fi

hdr "4. Deployment 副本偏差"
D=$(kubectl get deploy -A -o jsonpath='{range .items[*]}{.metadata.namespace}{"/"}{.metadata.name}{" "}{.spec.replicas}{" "}{.status.readyReplicas}{"\n"}{end}' \
    | awk '{r=($3==""?0:$3); if(r!=$2){print "  [FAIL] "$1"  desired="$2"  ready="r; f=1}} END{if(!f) print "  全部匹配"}')
echo "$D"
echo "$D" | grep -q FAIL && FAIL=$((FAIL+1))

hdr "5. 入口连通性（集群内直连控制器）"
CODE=$(kubectl -n ingress-nginx exec ds/ingress-nginx-controller -- curl -s -o /dev/null -w '%{http_code}' -H 'Host: lab.local' http://127.0.0.1:80/ 2>/dev/null)
if [ "$CODE" = "200" ]; then ok "lab.local -> $CODE"; else bad "lab.local -> $CODE"; fi

hdr "6. 节点资源"
kubectl top nodes 2>/dev/null || echo "  metrics-server 不可用"

echo
if [ "$FAIL" -eq 0 ]; then echo "结论：全部通过"; else echo "结论：发现 $FAIL 项异常"; fi
echo "日志：$LOG"