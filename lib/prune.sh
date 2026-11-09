# shellcheck shell=bash
# --prune: list go-yolo's images and cache volumes, and remove the ones nothing uses any more.
#
#   ✓ current  the base image of this go-yolo version; each project's image for its confirmed
#              plan; each cache volume in a project's confirmed plan
#   ✗ stale    an older base image; an image of an older plan; an image or volume whose project
#              directory is gone; a volume no longer in its project's plan; an image from before
#              the base image was called go-yolo-base
#
# Without a terminal it only lists (--yes removes the stale ones). Current images and volumes are
# only removed when you pick them yourself.

# image_status TAG PROJECT PLAN — print "current<TAB>why" or "stale<TAB>why" for one image.
image_status() {
  local tag=$1 project=$2 plan=$3
  case $tag in
    "$BASE_TAG") printf 'current\tthe base image of this go-yolo version\n' ;;
    "$BASE_LATEST") printf 'current\tpoints to the newest base image\n' ;;
    go-yolo-base:*) printf 'stale\tan older base image\n' ;;
    *)
      if [[ -z $project ]]; then
        printf 'stale\tfrom an older go-yolo (before go-yolo-base)\n'
      elif [[ ! -d $project ]]; then
        printf 'stale\tproject is gone: %s\n' "$project"
      elif [[ $plan == "$(confirmed_plan_hash "$project")" ]]; then
        printf 'current\t%s\n' "$project"
      else
        printf 'stale\tan older plan of %s\n' "$project"
      fi
      ;;
  esac
}

# volume_status PROJECT CACHE — print "current<TAB>why" or "stale<TAB>why" for one cache volume.
volume_status() {
  local project=$1 cache=$2
  if [[ ! -d $project ]]; then
    printf 'stale\tproject is gone: %s\n' "$project"
  elif awk -F'\t' -v cache="$cache" '$1 == "cache" && $3 == "volume" && $5 == cache { found = 1 }
                                      END { exit !found }' "$project/.go-yolo/plan" 2>/dev/null; then
    printf 'current\t%s cache of %s\n' "$cache" "$project"
  else
    printf 'stale\t%s cache, no longer in the plan of %s\n' "$cache" "$project"
  fi
}

# Print one line per go-yolo image: status, "image", tag, age, size, why (tab-separated).
image_statuses() {
  local tag id age size project plan status why i
  local tags=() ages=() sizes=() labels=()
  while IFS=$'\t' read -r tag id age size; do
    tags+=("$tag") ages+=("$age") sizes+=("$size")
  done < <(docker image ls --filter reference=go-yolo --filter reference=go-yolo-base \
             --format '{{.Repository}}:{{.Tag}}\t{{.ID}}\t{{.CreatedSince}}\t{{.Size}}')
  ((${#tags[@]})) || return 0

  # One line per tag: the project directory and plan hash labels ("" for none).
  mapfile -t labels < <(docker image inspect \
    --format '{{index .Config.Labels "go-yolo.project"}}{{"\t"}}{{index .Config.Labels "go-yolo.plan"}}' "${tags[@]}")
  for i in "${!tags[@]}"; do
    IFS=$'\t' read -r project plan <<<"${labels[i]:-}"
    IFS=$'\t' read -r status why < <(image_status "${tags[i]}" "${project:-}" "${plan:-}")
    printf '%s\timage\t%s\t%s\t%s\t%s\n' "$status" "${tags[i]}" "${ages[i]}" "${sizes[i]}" "$why"
  done
}

# Print one line per go-yolo cache volume: status, "volume", name, created, size, why.
volume_statuses() {
  local name project cache created status why
  local names=() labels=()
  local -A sizes=()
  mapfile -t names < <(docker volume ls --filter label=go-yolo.project --format '{{.Name}}')
  ((${#names[@]})) || return 0

  # `docker system df -v` has a table "VOLUME NAME  LINKS  SIZE" after "Local Volumes space usage:".
  while read -r name _ size; do
    sizes[$name]=$size
  done < <(docker system df -v 2>/dev/null \
             | awk '/^Local Volumes/ { in_table = 1; next } in_table && /^$/ && seen { exit }
                    in_table && $1 ~ /^go-yolo-/ { print; seen = 1 }')
  mapfile -t labels < <(docker volume inspect --format \
    '{{index .Labels "go-yolo.project"}}{{"\t"}}{{index .Labels "go-yolo.cache"}}{{"\t"}}{{.CreatedAt}}' "${names[@]}")
  for i in "${!names[@]}"; do
    IFS=$'\t' read -r project cache created <<<"${labels[i]:-}"
    IFS=$'\t' read -r status why < <(volume_status "$project" "$cache")
    printf '%s\tvolume\t%s\t%s\t%s\t%s\n' "$status" "${names[i]}" "${created%%T*}" "${sizes[${names[i]}]:-?}" "$why"
  done
}

# remove_items "image TAG" | "volume NAME" ... — remove each; report what happened.
remove_items() {
  local item type name command output
  for item in "$@"; do
    type=${item%% *} name=${item#* }
    command=(docker rmi --)
    if [[ $type == volume ]]; then command=(docker volume rm --); fi
    if output="$("${command[@]}" "$name" 2>&1)"; then
      note "removed $type $name"
    else
      warn "could not remove $type $name: ${output##*: }"
    fi
  done
}

# Remove cached base image package lists whose image no longer exists.
clean_package_cache() {
  local file id
  for file in "${XDG_CACHE_HOME:-$HOME_DIR/.cache}"/go-yolo/base-packages-*; do
    [[ -f $file ]] || continue
    id=${file##*/base-packages-}
    if ! docker image inspect "sha256:$id" >/dev/null 2>&1; then rm -f -- "$file"; fi
  done
}

prune_images() {
  local rows=() stale=() choices=() picked=() row status type name age size why answer mark
  command -v docker >/dev/null 2>&1 || die "docker not found on PATH"
  detect_host
  choose_base_image

  mapfile -t rows < <(image_statuses; volume_statuses)
  if ((${#rows[@]} == 0)); then
    note "no go-yolo images or cache volumes"
    clean_package_cache
    return 0
  fi

  note "images and cache volumes (✓ in use, ✗ stale):"
  for row in "${rows[@]}"; do
    IFS=$'\t' read -r status type name age size why <<<"$row"
    choices+=("$type $name"$'\t'"$why")
    if [[ $status == stale ]]; then
      stale+=("$type $name")
      mark="$(ui_paint red ✗)"
    else
      mark="$(ui_paint green ✓)"
    fi
    printf '  %s %-6s %-46s %8s  %-18s %s\n' "$mark" "$type" "$name" "$size" "$age" "$(ui_paint dim "$why")" >&2
  done
  note "image sizes include the layers images share, so they don't add up"

  if ((YES)); then
    if ((${#stale[@]})); then remove_items "${stale[@]}"; else note "nothing stale to remove"; fi
  elif [[ ! -t 0 || ! -t 2 ]]; then
    note "run in a terminal to choose what to remove, or pass --yes to remove the ✗ ones"
  else
    if ((${#stale[@]})); then
      read -r -p "go-yolo: remove the ${#stale[@]} ✗ ones? [y]es [n]o [p]ick: " answer
    else
      read -r -p "go-yolo: nothing is stale; pick some to remove anyway? [p]ick [n]o: " answer
    fi
    case $answer in
      y|yes) remove_items "${stale[@]}" ;;
      p|pick)
        # Each choice is "type name<TAB>why"; remove the picked ones.
        while IFS= read -r row; do
          picked+=("${row%%$'\t'*}")
        done < <(ui_pick_many 'remove:' "${choices[@]}")
        if ((${#picked[@]})); then remove_items "${picked[@]}"; else note "nothing removed"; fi
        ;;
      *) note "nothing removed" ;;
    esac
  fi
  clean_package_cache
}
