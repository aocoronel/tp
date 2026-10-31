if __tp_executable=$(command -v tp); then
  cd() {
    if __tp_path=$($__tp_executable "$@"); then
      [[ "$__tp_path" != "" ]] && \builtin cd "$__tp_path"
    fi
  }
fi
