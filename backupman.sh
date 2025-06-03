#!/usr/bin/bash

EDRIVE_DAT_DIR="/mnt/edrive/data"
PHOTO_DIR="${EDRIVE_DAT_DIR}/photos"

b2_photo_conf="b2-photos"
b2_photo_dir="muffledm-photos/photos"
SESSION_NAME="rclone-backups"

echo "Starting backup process..."

# Function to get photo backups from remote.
get_photo_backups() {
  sudo docker exec -it rclone-backups rclone lsf ${b2_photo_conf}:${b2_photo_dir} 2>/dev/null
}

# Function to check if a tmux sessions exists
session_exists() {
  tmux has-session -t "$SESSION_NAME" 2>/dev/null
}



# Check if session has running processes
session_has_running_processes() {
  local session_name="$1"

  # Get the number of panes in the session
  local pane_count=$(tmux list-panes -t "$session_name" -F "#{pane_pid}" 2>/dev/null | wc -l)

  if [[ $pane_count -eq 0 ]]; then
    return 1
  fi

  # Check pane for active processes excluding the shell
  local running_processes=0
  while IFS= read -r pane_pid; do
    local child_count=$(pgrep -P "${pane_pid}" 2>/dev/null | wc -l)
    if [[ ${child_count} -gt 0 ]]; then
      running_processes=$((running_processes + 1))
    fi
  done < <(tmux list-panes -t "${session_name}" -F "#{pane_pid}" 2>/dev/null)

  [[ ${running_processes} -gt 0 ]]
}

if session_exists; then
  echo "Session ${SESSION_NAME} exists. Checkign for running processes..."
  if session_has_running_processes "${SESSION_NAME}"; then
    echo "Session ${SESSION_NAME} has running processes. Exiting to avoid interference."
    exit 0
  else
    echo "Session ${SESSION_NAME} exists but has no running processes. Killing session."
    tmux kill-session -t ${SESSION_NAME}
  fi
else
  echo "Session ${SESSION_NAME} does not exist."
fi

echo "Creating new tmux session ${SESSION_NAME} at ${EDRIVE_DAT_DIR}"
tmux new-session -d -s ${SESSION_NAME} -c ${EDRIVE_DAT_DIR}

echo "Getting list of remote files..."
mapfile -t photo_backups < <(get_photo_backups)

if [[ ${#photo_backups[@]} -eq 0 ]]; then
  echo "Warning: Could not get remote file list or remote is empty"
fi

# Create associative array for faster lookups
declare -A remote_files
for file in ${photo_backups[@]}; do
  remote_files[${file}]=1
done

echo "Fount ${#photo_backups[@]} file in remote backup"

# Find local files that need to be backed up
files_to_backup=()
if [[ -d ${PHOTO_DIR} ]]; then
  echo "Scanning local directory: ${PHOTO_DIR}"
  while IFS= read -r -d '' local_file; do
    rel_path=$(realpath --relative-to="${PHOTO_DIR}" "${local_file}")
    echo "Found file: ${rel_path}"

    if [[ -z "${remote_files[$rel_path]}" ]]; then
      files_to_backup+=(${rel_path})
    fi
  done < <(find ${PHOTO_DIR} -mindepth 1 -maxdepth 1 -type d -print0)
else
  echo "Error: Local photo directory ${PHOTO_DIR} does not exist"
  tmux kill-session -t ${SESSION_NAME}
  exit 1
fi

echo "Found ${#files_to_backup[@]} files that need to be backed up"

if [[ ${#files_to_backup[@]} -eq 0 ]]; then
  echo "No files need to be backed up. All files are already in remote."
  tmux kill-session -t ${SESSION_NAME}
  exit 0
fi

# Create transfer jobs in seperate tmux windows
window_count=0
max_concurrent_transfers=5

for file in ${files_to_backup[@]}; do
  window_count=$((window_count + 1))
  window_name="transfer-${window_count}"

  echo "Creating transfer window: ${window_name} for file: ${file}"

  tmux new-window -t "${SESSION_NAME}" -n "${window_name}"
  
  # Build rclone command
  local_file_path="${PHOTO_DIR}/${file}"
  remote_path="${b2_photo_conf}:${b2_photo_dir}/${file}.tar.gz"
  rclone_cmd="sudo docker exec -it rclone-backups sh -c \"tar -zcvf - /data/photos/${file} | rclone rcat ${remote_path} -v --s3-chunk-size 200M\""

  tmux send-keys -t "${SESSION_NAME}:${window_name}" "${rclone_cmd}" C-m
done

# Kill the initial empty window (window 0)
tmux kill-window -t "$SESSION_NAME:0" 2>/dev/null

echo ""
echo "Backup process started!"
echo "Created $window_count transfer windows in tmux session '$SESSION_NAME'"
echo ""
echo "To monitor the transfers, run:"
echo "  tmux attach-session -t $SESSION_NAME"
echo ""
echo "To list all windows: Ctrl+b w"
echo "To switch between windows: Ctrl+b [window-number]"
echo "To detach from session: Ctrl+b d"
echo ""
echo "The session will remain active until all transfers complete."
