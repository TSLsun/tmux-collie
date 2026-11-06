# shellcheck shell=bash
# Sourced by bin/collie: race and pick.

cmd_race() {
  local id="" count=0 agents="" repo="" model="" effort="" prompt="" base c name branch path agent n child rc=0
  while [ $# -gt 0 ]; do
    case $1 in
      -n) need_value race "-n needs a count" "${2:-}"; count=$2; shift ;;
      --agent) need_value race "--agent needs names" "${2:-}"; agents=$2; shift ;;
      --model) need_value race "--model needs a name" "${2:-}"; model=$2; shift ;;
      --effort) need_value race "--effort needs a level" "${2:-}"; effort=$2; shift ;;
      -r) need_value race "-r needs a repo" "${2:-}"; repo=$2; shift ;;
      -p) need_value race "-p needs a prompt" "${2:-}"; prompt=$2; shift ;;
      -*) die "race: unknown option $1" ;;
      *) [ -z "$id" ] || die "race: too many arguments"; id=$1 ;;
    esac
    shift
  done
  [ -n "$id" ] || id=${COLLIE_TASK:-}
  [ -n "$id" ] || die "usage: collie race <id> -n N [--agent a,b,c] [--model m] [--effort e] [-r repo] [-p prompt]"
  task_id "$id"
  [[ $count =~ ^[2-9]$ ]] || die "race: -n must be 2..9"
  command -v tmux >/dev/null || die "race: tmux required"
  local d="$TASKS_DIR/$id" firstc="" firstb="" firstp="" firstn="" spec="" agents_csv=${agents//,/ } default_agent wtroot setup_backup setup_had_repos=0 tdir="$TASKS_DIR/$id"
  local -a SETUP_FILES=() SETUP_LINKS=()
  if [ -f "$d/events.log" ] && awk -F'\t' '$2 == "race_started" { found=1 } END { exit !found }' "$d/events.log"; then
    die "race: task '$id' already has a race; previous races cannot be reused"
  fi
  while IFS=$TAB read -r name c branch path; do
    if [ -z "$repo" ] || [ "$name" = "$repo" ]; then firstn=$name firstc=$c firstb=$branch firstp=$path; break; fi
  done <"$d/repos.tsv"
  [ -n "$firstn" ] || die "race: repo '$repo' is not part of task '$id'"
  [ "$firstc" != - ] || die "race: folders are not supported"
  [ -d "$firstp" ] || die "race: missing worktree $firstp"
  base=$(git -C "$firstp" rev-parse "refs/heads/$firstb") || die "race: cannot resolve task branch $firstb"
  local -a planned=() agent_list=()
  if [ -n "$agents" ]; then
    IFS=, read -r -a agent_list <<<"$agents"
    [ "${#agent_list[@]}" -gt 0 ] || die "race: empty --agent list"
  fi
  run_agent; default_agent=$RUN_AGENT
  for ((n=1; n<=count; n++)); do
    child="$id-$n"
    valid_id "$child" || die "race: candidate id '$child' exceeds 40 characters"
    [ ! -e "$TASKS_DIR/$child" ] && [ ! -L "$TASKS_DIR/$child" ] || die "race: task '$child' already exists; previous races cannot be reused"
    branch="exp/$child"; repo_at "$firstp" || die "race: cannot resolve repo root"; wtroot=$R_ROOT; path="$wtroot/${branch//\//-}"
    git --git-dir="$firstc" show-ref -q --verify "refs/heads/$branch" && die "race: branch '$branch' already exists; previous races cannot be reused"
    [ ! -e "$path" ] && [ ! -L "$path" ] || die "race: $path already exists"
    planned+=("$child" "$branch" "$path")
  done
  # All paths and refs are checked before the first child is created.
  log_event "$id" race_started "base=$base repo=$firstn n=$count"
  for ((n=1; n<=count; n++)); do
    child=${planned[(n-1)*3]}; branch=${planned[(n-1)*3+1]}; path=${planned[(n-1)*3+2]}
    mkdir -p "$TASKS_DIR/$child/repos" || { warn "race: partial creation; retained prior candidates and branches"; return 1; }
    cp "$d/TASK.md" "$TASKS_DIR/$child/TASK.md" || { warn "race: partial creation; retained prior candidates and branches"; return 1; }
    printf '%s\t%s\n' "$id" "$n" >"$TASKS_DIR/$child/race.tsv" || { warn "race: partial creation; retained prior candidates and branches"; return 1; }
    setup_backup=$(mktemp -d) || return 1
    if ! add_worktree "$firstc" "$path" "$branch" "$base"; then
      warn "race: partial creation at $child; retained any created exp/* branches and worktrees"
      rm -rf "$setup_backup"
      return 1
    fi
    agent=$default_agent
    [ "${#agent_list[@]}" -eq 0 ] || agent=${agent_list[$(((n-1)%${#agent_list[@]}))]}
    log_event "$id" race_candidate "task=$child agent=$agent branch=$branch" || return 1
    printf '%s\t%s\t%s\t%s\n' "$firstn" "$firstc" "$branch" "$path" >"$TASKS_DIR/$child/repos.tsv" || { warn "race: partial creation; retained exp/$child"; rm -rf "$setup_backup"; return 1; }
    if ! link_worktree "$child" "$firstn" "$firstc" "$branch" "$path"; then
      warn "race: partial creation; retained exp/$child"
      rm -rf "$setup_backup"
      return 1
    fi
    rm -rf "$setup_backup"
    log_event "$child" task_created || return 1
  done
  for ((n=1; n<=count; n++)); do
    child=${planned[(n-1)*3]}
    local -a runargs=("$child" --agent "$default_agent")
    agent=$default_agent
    [ "${#agent_list[@]}" -eq 0 ] || agent=${agent_list[$(((n-1)%${#agent_list[@]}))]}
    runargs=("$child" --agent "$agent")
    [ -z "$model" ] || runargs+=(--model "$model")
    [ -z "$effort" ] || runargs+=(--effort "$effort")
    [ -n "$prompt" ] || prompt="Work independently on this race candidate. Read .collie/TASK.md, complete the task, write .collie/REPORT.md, then run: collie signal done"
    runargs+=(-p "$prompt")
    if (cmd_run "${runargs[@]}"); then :; else rc=$?; warn "race: run failed for $child (candidate retained)"; fi
    local run=-
    [ ! -f "$TASKS_DIR/$child/events.log" ] || run=$(awk -F'\t' '$2 == "run_started" { n++ } END { if (n) print n; else print "-" }' "$TASKS_DIR/$child/events.log")
    printf '%s %s %s\n' "$child" "$run" "${planned[(n-1)*3+2]}"
  done
  return "$rc"
}

cmd_pick() {
  [ $# -eq 2 ] || die "usage: collie pick <id> <n>"
  local id=$1 n=$2 child d c branch path task_branch head current base repo line candidate
  task_id "$id"
  [[ $n =~ ^[1-9]$ ]] || die "pick: candidate number must be 1..9"
  child="$id-$n"
  d="$TASKS_DIR/$id"
  [ -f "$TASKS_DIR/$child/TASK.md" ] || die "pick: no candidate '$child'"
  line=$(awk -F'\t' '$2 == "race_started" { print $3; exit }' "$d/events.log")
  [ -n "$line" ] || die "pick: task '$id' has no recorded race"
  base=$(awk -F' ' '{ for(i=1;i<=NF;i++) if($i ~ /^base=/) { sub(/^base=/,"",$i); print $i } }' <<<"$line")
  repo=$(awk -F' ' '{ for(i=1;i<=NF;i++) if($i ~ /^repo=/) { sub(/^repo=/,"",$i); print $i } }' <<<"$line")
  [ -n "$base" ] && [ -n "$repo" ] || die "pick: malformed race metadata"
  candidate=$(awk -F'\t' -v wanted="$child" '$2=="race_candidate" { if(index($3,"task=" wanted " ") || $3 ~ ("task=" wanted "$")) found=1 } END { print found }' "$d/events.log")
  [ "$candidate" = 1 ] || die "pick: '$child' is not a candidate of '$id'"
  local name _
  while IFS=$TAB read -r name c task_branch path; do [ "$name" = "$repo" ] && break; done <"$d/repos.tsv"
  [ "$name" = "$repo" ] || die "pick: raced repo '$repo' is no longer recorded"
  branch="exp/$child"
  IFS=$TAB read -r name c _ path <"$TASKS_DIR/$child/repos.tsv"
  [ "$name" = "$repo" ] || die "pick: candidate '$child' does not use raced repo '$repo'"
  [ -d "$path" ] || die "pick: candidate worktree missing: $path"
  [ -d "${path%/*}" ] || die "pick: candidate worktree missing: $path"
  # The parent task repo's worktree is located from its recorded repos.tsv row.
  while IFS=$TAB read -r name c task_branch path; do [ "$name" = "$repo" ] && break; done <"$d/repos.tsv"
  [ -d "$path" ] || die "pick: task worktree missing: $path"
  [ -z "$(git -C "$path" status --porcelain)" ] || die "pick: task worktree is dirty; commit or clean it first"
  current=$(git -C "$path" symbolic-ref -q HEAD) || die "pick: task worktree is detached"
  [ "$current" = "refs/heads/$task_branch" ] || die "pick: task worktree is not on $task_branch"
  head=$(git -C "$path" rev-parse "refs/heads/$task_branch") || die "pick: cannot resolve task branch $task_branch"
  [ "$head" = "$base" ] || die "pick: task branch moved since race base; refusing to overwrite it"
  git -C "$path" merge --ff-only "$branch" || die "pick: fast-forward failed; task branch unchanged"
  local commit
  commit=$(git -C "$path" rev-parse HEAD) || return 1
  log_event "$id" race_picked "n=$n task=$child commit=$commit"
  printf 'picked %s (%s); candidates remain on exp/* branches\n' "$child" "$commit"
  awk -F'\t' '$2 == "race_candidate" { n=split($3,a," "); for(i=1;i<=n;i++) if(a[i] ~ /^task=/) { sub(/^task=/,"",a[i]); print "hint: collie archive " a[i] } }' "$d/events.log"
}
  
