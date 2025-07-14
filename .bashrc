echo "hello world!"
echo "SSH_CONNECTION='$SSH_CONNECTION'"
echo "TMUX='$TMUX'"

if [ -n "$SSH_CONNECTION" ] && [ -z "$TMUX" ]; then
  echo "✨ Bro detected. Storybook is loading..."
  
  # Check if session already exists
  if ! tmux has-session -t boyo 2>/dev/null; then
    # Create session and run command
    if [ -d ~/dev/some-ui ]; then
      tmux new-session -d -s boyo -c ~/dev/some-ui 'pnpm storybook'
    else
      echo "Project directory not found, creating basic session..."
      tmux new-session -d -s boyo
    fi
  fi
  
  # Attach to session
  tmux attach -t boyo
fi
