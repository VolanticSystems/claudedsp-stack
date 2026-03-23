# claudedsp Setup

Create `/usr/local/bin/claudedsp` to run Claude Code as user `claude` with `--dangerously-skip-permissions`:

```bash
cat > /usr/local/bin/claudedsp << 'EOF'
#!/bin/bash
sudo -u claude bash -c "cd /root/rich-rules && /usr/local/bin/claude --dangerously-skip-permissions $*"
EOF
chmod +x /usr/local/bin/claudedsp
```

## Prerequisites

- User `claude` must exist
- `claude` needs read/write access to the working directory
- Claude Code must be installed at `/usr/local/bin/claude`
- Adjust the `cd` path to match the project directory on that box
