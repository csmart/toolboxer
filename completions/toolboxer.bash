# Bash completion for toolboxer
# Source this file or copy it to /etc/bash_completion.d/ or
# ~/.local/share/bash-completion/completions/

_toolboxer() {
    local cur prev words cword
    _init_completion || return

    local commands="create enter run list stop rm rmi help"
    local global_opts="-m --mount -A --ai-agents -y --assumeyes --privileged --isolated -h --help"

    # Find the subcommand position (skip global options and their arguments)
    local cmd_idx cmd=""
    for ((cmd_idx = 1; cmd_idx < cword; cmd_idx++)); do
        case "${words[cmd_idx]}" in
            -m|--mount)
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
        -m|--mount)
            _filedir -d
            return
            ;;
    esac

    # No subcommand yet — complete with global options or commands
    if [[ -z "$cmd" ]]; then
        if [[ "$cur" == -* ]]; then
            COMPREPLY=($(compgen -W "$global_opts" -- "$cur"))
        else
            COMPREPLY=($(compgen -W "$commands" -- "$cur"))
        fi
        return
    fi

    # Subcommand-specific completions
    case "$cmd" in
        create)
            case "$prev" in
                -d|--distro)
                    COMPREPLY=($(compgen -W "fedora rhel centos rocky ubuntu debian arch opensuse-leap opensuse-tumbleweed" -- "$cur"))
                    return
                    ;;
                -i|--image)
                    local images
                    images=$(podman image list --format '{{.Repository}}:{{.Tag}}' 2>/dev/null)
                    COMPREPLY=($(compgen -W "$images" -- "$cur"))
                    return
                    ;;
                -r|--release)
                    return  # user must type the release
                    ;;
                -m|--mount)
                    _filedir -d
                    return
                    ;;
                --authfile)
                    _filedir
                    return
                    ;;
            esac
            if [[ "$cur" == -* ]]; then
                COMPREPLY=($(compgen -W "-d --distro -i --image -r --release -m --mount -A --ai-agents --authfile --privileged --isolated -h --help" -- "$cur"))
            fi
            ;;
        enter)
            case "$prev" in
                -d|--distro)
                    COMPREPLY=($(compgen -W "fedora rhel centos rocky ubuntu debian arch opensuse-leap opensuse-tumbleweed" -- "$cur"))
                    return
                    ;;
                -r|--release) return ;;
            esac
            if [[ "$cur" == -* ]]; then
                COMPREPLY=($(compgen -W "-d --distro -r --release -h --help" -- "$cur"))
            else
                local containers
                containers=$(podman container list --all --filter "label=toolboxer=true" --format '{{.Names}}' 2>/dev/null)
                COMPREPLY=($(compgen -W "$containers" -- "$cur"))
            fi
            ;;
        run)
            case "$prev" in
                -c|--container)
                    local containers
                    containers=$(podman container list --all --filter "label=toolboxer=true" --format '{{.Names}}' 2>/dev/null)
                    COMPREPLY=($(compgen -W "$containers" -- "$cur"))
                    return
                    ;;
                -d|--distro)
                    COMPREPLY=($(compgen -W "fedora rhel centos rocky ubuntu debian arch opensuse-leap opensuse-tumbleweed" -- "$cur"))
                    return
                    ;;
                -r|--release) return ;;
                --preserve-fds) return ;;
            esac
            if [[ "$cur" == -* ]]; then
                COMPREPLY=($(compgen -W "-c --container -d --distro -r --release --preserve-fds -h --help" -- "$cur"))
            else
                COMPREPLY=($(compgen -c -- "$cur"))
            fi
            ;;
        list)
            COMPREPLY=($(compgen -W "-c --containers -i --images -h --help" -- "$cur"))
            ;;
        rm)
            case "$prev" in
                -d|--distro)
                    COMPREPLY=($(compgen -W "fedora rhel centos rocky ubuntu debian arch opensuse-leap opensuse-tumbleweed" -- "$cur"))
                    return
                    ;;
                -r|--release) return ;;
            esac
            if [[ "$cur" == -* ]]; then
                COMPREPLY=($(compgen -W "-a --all -f --force -d --distro -r --release -h --help" -- "$cur"))
            else
                local containers
                containers=$(podman container list --all --filter "label=toolboxer=true" --format '{{.Names}}' 2>/dev/null)
                COMPREPLY=($(compgen -W "$containers" -- "$cur"))
            fi
            ;;
        rmi)
            if [[ "$cur" == -* ]]; then
                COMPREPLY=($(compgen -W "-a --all -f --force -h --help" -- "$cur"))
            else
                local images
                images=$(podman image list --filter "reference=*toolbox*" --format '{{.Repository}}:{{.Tag}}' 2>/dev/null)
                COMPREPLY=($(compgen -W "$images" -- "$cur"))
            fi
            ;;
        stop)
            case "$prev" in
                -d|--distro)
                    COMPREPLY=($(compgen -W "fedora rhel centos rocky ubuntu debian arch opensuse-leap opensuse-tumbleweed" -- "$cur"))
                    return
                    ;;
                -r|--release) return ;;
            esac
            if [[ "$cur" == -* ]]; then
                COMPREPLY=($(compgen -W "-d --distro -r --release -h --help" -- "$cur"))
            else
                local containers
                containers=$(podman container list --all --filter "label=toolboxer=true" --format '{{.Names}}' 2>/dev/null)
                COMPREPLY=($(compgen -W "$containers" -- "$cur"))
            fi
            ;;
    esac
}

complete -F _toolboxer toolboxer
