echo "hello world!"
echo "SSH_CONNECTION='$SSH_CONNECTION'"
echo "TMUX='$TMUX'"

if [ -n "$SSH_CONNECTION" ] && [ -z "$TMUX" ]; then
  # Check if session already exists
  if ! tmux has-session -t boyo 2>/dev/null; then
    if [ -d ~/dev/some-ui ]; then
      tmux new-session -d -s boyo -c ~/dev/some-ui
    else
      tmux new-session -d -s boyo
    fi
  fi
  
  # Attach to session
  tmux attach -t boyo
fi
