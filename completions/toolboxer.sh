# shellcheck shell=bash
# Bash completion for toolboxer
# Source this file or copy it to /etc/bash_completion.d/ or
# ~/.local/share/bash-completion/completions/

_toolboxer() {
    local cur prev words cword
    _init_completion || return

    local distros="fedora rhel centos rocky ubuntu debian arch opensuse-leap opensuse-tumbleweed opensuse suse leap tumbleweed archlinux"
    local agents="claude codex gemini qwen cursor grok continue copilot goose opencode crush aider llm sgpt interpreter"
    local commands="create enter run list stop rm rmi config provision help"
    local global_opts="-m --mount -A --ai-agents --agent --no-ai-agents -y --assumeyes --no-assumeyes --privileged --no-privileged --isolated --no-isolated -h --help"

    # Find the subcommand position (skip global options and their arguments)
    local cmd_idx cmd=""
    for ((cmd_idx = 1; cmd_idx < cword; cmd_idx++)); do
        case "${words[cmd_idx]}" in
            -m|--mount|--agent)
                ((cmd_idx++))  # skip the argument
                ;;
            -*)
                ;;
            *)
                cmd="${words[cmd_idx]}"
                break
                ;;
        esac
    done

    # If completing a global option's argument
    case "$prev" in
        --agent)
            mapfile -t COMPREPLY < <(compgen -W "$agents" -- "$cur")
            return ;;
        -m|--mount)
            _filedir
            return
            ;;
    esac

    # No subcommand yet — complete with global options or commands
    if [[ -z "$cmd" ]]; then
        if [[ "$cur" == -* ]]; then
            mapfile -t COMPREPLY < <(compgen -W "$global_opts" -- "$cur")
        else
            mapfile -t COMPREPLY < <(compgen -W "$commands" -- "$cur")
        fi
        return
    fi

    # Subcommand-specific completions
    case "$cmd" in
        create)
            case "$prev" in
                -d|--distro)
                    mapfile -t COMPREPLY < <(compgen -W "$distros" -- "$cur")
                    return
                    ;;
                -i|--image)
                    local images
                    images=$(podman image list --format '{{.Repository}}:{{.Tag}}' 2>/dev/null)
                    mapfile -t COMPREPLY < <(compgen -W "$images" -- "$cur")
                    return
                    ;;
                -r|--release)
                    return  # user must type the release
                    ;;
                -m|--mount)
                    _filedir
                    return
                    ;;
                --authfile)
                    _filedir
                    return
                    ;;
                --pull)
                    mapfile -t COMPREPLY < <(compgen -W "missing always newer never" -- "$cur")
                    return
                    ;;
            esac
            if [[ "$cur" == -* ]]; then
                mapfile -t COMPREPLY < <(compgen -W "-d --distro -i --image -r --release -m --mount -A --ai-agents --agent --no-ai-agents --authfile --pull --privileged --no-privileged --isolated --no-isolated -h --help" -- "$cur")
            fi
            ;;
        enter)
            case "$prev" in
                -d|--distro)
                    mapfile -t COMPREPLY < <(compgen -W "$distros" -- "$cur")
                    return
                    ;;
                -r|--release) return ;;
            esac
            if [[ "$cur" == -* ]]; then
                mapfile -t COMPREPLY < <(compgen -W "-d --distro -r --release -h --help" -- "$cur")
            else
                local containers
                containers=$(podman container list --all --filter "label=toolboxer=true" --format '{{.Names}}' 2>/dev/null)
                mapfile -t COMPREPLY < <(compgen -W "$containers" -- "$cur")
            fi
            ;;
        run)
            case "$prev" in
                -c|--container)
                    local containers
                    containers=$(podman container list --all --filter "label=toolboxer=true" --format '{{.Names}}' 2>/dev/null)
                    mapfile -t COMPREPLY < <(compgen -W "$containers" -- "$cur")
                    return
                    ;;
                -d|--distro)
                    mapfile -t COMPREPLY < <(compgen -W "$distros" -- "$cur")
                    return
                    ;;
                -r|--release) return ;;
                --preserve-fds) return ;;
            esac
            if [[ "$cur" == -* ]]; then
                mapfile -t COMPREPLY < <(compgen -W "-c --container -d --distro -r --release --preserve-fds -h --help" -- "$cur")
            else
                mapfile -t COMPREPLY < <(compgen -c -- "$cur")
            fi
            ;;
        list)
            mapfile -t COMPREPLY < <(compgen -W "-c --containers -i --images -h --help" -- "$cur")
            ;;
        rm)
            case "$prev" in
                -d|--distro)
                    mapfile -t COMPREPLY < <(compgen -W "$distros" -- "$cur")
                    return
                    ;;
                -r|--release) return ;;
            esac
            if [[ "$cur" == -* ]]; then
                mapfile -t COMPREPLY < <(compgen -W "-a --all -f --force -d --distro -r --release -h --help" -- "$cur")
            else
                local containers
                containers=$(podman container list --all --filter "label=toolboxer=true" --format '{{.Names}}' 2>/dev/null)
                mapfile -t COMPREPLY < <(compgen -W "$containers" -- "$cur")
            fi
            ;;
        rmi)
            if [[ "$cur" == -* ]]; then
                mapfile -t COMPREPLY < <(compgen -W "-a --all -f --force -h --help" -- "$cur")
            else
                local images
                images=$(podman image list --format '{{.Repository}}:{{.Tag}}' 2>/dev/null)
                mapfile -t COMPREPLY < <(compgen -W "$images" -- "$cur")
            fi
            ;;
        config)
            if [[ "$cur" == -* ]]; then
                mapfile -t COMPREPLY < <(compgen -W "-h --help" -- "$cur")
            fi
            ;;
        provision)
            case "$prev" in
                -d|--distro)
                    mapfile -t COMPREPLY < <(compgen -W "$distros" -- "$cur")
                    return
                    ;;
                -r|--release) return ;;
            esac
            if [[ "$cur" == -* ]]; then
                mapfile -t COMPREPLY < <(compgen -W "-d --distro -r --release -h --help" -- "$cur")
            else
                local containers
                containers=$(podman container list --all --filter "label=toolboxer=true" --format '{{.Names}}' 2>/dev/null)
                mapfile -t COMPREPLY < <(compgen -W "$containers" -- "$cur")
            fi
            ;;
        stop)
            case "$prev" in
                -d|--distro)
                    mapfile -t COMPREPLY < <(compgen -W "$distros" -- "$cur")
                    return
                    ;;
                -r|--release) return ;;
            esac
            if [[ "$cur" == -* ]]; then
                mapfile -t COMPREPLY < <(compgen -W "-d --distro -r --release -h --help" -- "$cur")
            else
                local containers
                containers=$(podman container list --all --filter "label=toolboxer=true" --format '{{.Names}}' 2>/dev/null)
                mapfile -t COMPREPLY < <(compgen -W "$containers" -- "$cur")
            fi
            ;;
    esac
}

complete -F _toolboxer toolboxer
