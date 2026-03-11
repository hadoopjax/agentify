FROM node:22-slim

RUN apt-get update && apt-get install -y \
    git \
    jq \
    curl \
    ripgrep \
    python3 \
    && rm -rf /var/lib/apt/lists/*

# gh CLI
RUN curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
    | dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
    | tee /etc/apt/sources.list.d/github-cli.list > /dev/null \
    && apt-get update && apt-get install -y gh && rm -rf /var/lib/apt/lists/*

# Codex + Claude Code
RUN npm install -g @openai/codex @anthropic-ai/claude-code

# agentify
COPY . /opt/agentify
RUN chmod +x /opt/agentify/bin/agentify /opt/agentify/lib/loop.sh
ENV PATH="/opt/agentify/bin:$PATH"

WORKDIR /repo
EXPOSE 4242

ENTRYPOINT ["agentify"]
CMD ["run"]
