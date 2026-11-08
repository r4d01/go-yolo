# shellcheck shell=bash
# --prune: list go-yolo's images and remove the ones nothing uses any more.
#
#   ✓ current  the base image of this go-yolo version; each project's image for its confirmed plan
#   ✗ stale    an older base image; an image of an older plan; an image whose project directory
#              is gone; an image from before the base image was called go-yolo-base
#
# Without a terminal it only lists (--yes removes the stale images). Current images are only
# removed when you pick them yourself.

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

# Print one line per go-yolo image: status, tag, age, size, why (tab-separated).
image_statuses() {
  local line tag id age size project plan status why i
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
    printf '%s\t%s\t%s\t%s\t%s\n' "$status" "${tags[i]}" "${ages[i]}" "${sizes[i]}" "$why"
  done
}

# remove_images TAG... — docker rmi each tag; report what happened.
remove_images() {
  local tag output
  for tag in "$@"; do
    if output="$(docker rmi -- "$tag" 2>&1)"; then
      note "removed $tag"
    else
      warn "could not remove $tag: ${output##*: }"
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
  local rows=() stale=() choices=() picked=() row status tag age size why answer
  command -v docker >/dev/null 2>&1 || die "docker not found on PATH"
  detect_host
  choose_base_image

  mapfile -t rows < <(image_statuses)
  if ((${#rows[@]} == 0)); then
    note "no go-yolo images"
    clean_package_cache
    return 0
  fi

  note "images (✓ in use, ✗ stale):"
  for row in "${rows[@]}"; do
    IFS=$'\t' read -r status tag age size why <<<"$row"
    choices+=("$tag"$'\t'"$why")
    if [[ $status == stale ]]; then
      stale+=("$tag")
      printf '  %s %-46s %8s  %-18s %s\n' "$(ui_paint red ✗)" "$tag" "$size" "$age" "$(ui_paint dim "$why")" >&2
    else
      printf '  %s %-46s %8s  %-18s %s\n' "$(ui_paint green ✓)" "$tag" "$size" "$age" "$(ui_paint dim "$why")" >&2
    fi
  done
  note "sizes include the layers images share, so they don't add up"

  if ((YES)); then
    if ((${#stale[@]})); then remove_images "${stale[@]}"; else note "nothing stale to remove"; fi
  elif [[ ! -t 0 || ! -t 2 ]]; then
    note "run in a terminal to choose what to remove, or pass --yes to remove the ✗ images"
  else
    if ((${#stale[@]})); then
      read -r -p "go-yolo: remove the ${#stale[@]} ✗ images? [y]es [n]o [p]ick: " answer
    else
      read -r -p "go-yolo: nothing is stale; pick images to remove anyway? [p]ick [n]o: " answer
    fi
    case $answer in
      y|yes) remove_images "${stale[@]}" ;;
      p|pick)
        # Each choice is "tag<TAB>why"; remove the picked tags.
        while IFS= read -r row; do
          picked+=("${row%%$'\t'*}")
        done < <(ui_pick_many 'remove:' "${choices[@]}")
        if ((${#picked[@]})); then remove_images "${picked[@]}"; else note "nothing removed"; fi
        ;;
      *) note "nothing removed" ;;
    esac
  fi
  clean_package_cache
}
