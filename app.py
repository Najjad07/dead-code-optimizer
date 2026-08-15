import streamlit as st
import subprocess
import os
import platform
import tempfile
import uuid

st.set_page_config(page_title="Dead Code Optimizer", layout="wide")

st.title("Welcome to the Dead Code Optimizer")

st.markdown("""
### About This Project
This system is a Compiler Design Lab project designed to analyze basic C source code.
It identifies and removes unnecessary statements or dead variables without altering the core logic.
Developed as an academic submission for the Computer Science and Engineering department at Daffodil International University (Batch 67), this tool utilizes Flex/Lex and Bison/Yacc for lexical and syntax analysis.
""")

with st.expander("ℹ️ What kind of C code does this tool understand?"):
    st.markdown("""
**Supported:** `int/float/double/char/void/long/short/unsigned` declarations (including
`int a, b = 5, c;`), assignment (`=`, `+=`, `-=`, `*=`, `/=`, `++`, `--`), `if / else`,
`while`, `do...while`, `for`, `break`, `continue`, `return`, function definitions with
parameters, `printf(...)`/`print(...)`, comparisons (`< > <= >= == !=`), logical
`&& || !`, the ternary `?:`, arrays (`a[i]`), and both `//` and `/* */` comments.

**Not supported (will show a syntax error):** pointers/`*`-dereference, `struct`/`enum`,
`switch`, multi-dimensional arrays, `sizeof`, string functions (`strcpy`, etc.),
function calls used *inside* an expression (e.g. `x = foo() + 1;` — call `foo();` as
its own statement instead), multiple source files, and standard headers being anything
other than ignored `#include` lines.

**Comments are also removed from the optimized output** — both `//` line
comments and `/* ... */` block comments (even ones spanning multiple lines)
are stripped. If a comment shares a line with real code (`int x = 5; // note`),
only the comment part is removed and the code stays.

**Variables are tracked per-function**, so `int i;` in one function and an
unrelated `int i;` in another function are correctly treated as two separate
variables — one can be flagged dead while the other, genuinely used one, is
kept. Array and string initializers (`int arr[3] = {1, 2, 3};`,
`char name[20] = "hello";`) are also supported now.

**Unreachable code after `return` is removed.** Any statements that come
after an unconditional `return` inside the same `{ }` block — and can never
execute — are stripped from the output.

**Dead branches from constant conditions are removed.** `if (0) { ... }`,
`if (1) { ... } else { ... }`, and `while (0) { ... }` are evaluated at
compile time; the branch/loop body that can never run is stripped. This only
applies when that branch is written as an explicit `{ }` block — a brace-less
single-statement body (`if (0) doThing();`) is left alone, since safely
deleting it without risking invalid C (e.g. a dangling `else`) isn't always
possible with this tool's line-based approach.

**What counts as "dead code" here:**
- **Dead variable** — declared but never read anywhere (its declaration line is removed).
- **Dead store** — assigned a value that is never read before the program ends or the
  variable is reassigned (only whole never-read variables are removed in this version —
  see note below).
- **Constant folding** — an expression made only of literals (e.g. `10 + 20`) is
  evaluated at compile time and reported, though the source line itself is left intact
  since it isn't *dead*, just simplifiable.

**Known limitation:** removal is based on "was this variable read anywhere in
its scope at all," not full control-flow liveness. So `x = 5; x = 10; printf(x);`
will **not** flag the first `x = 5;` as dead, because `x` is read later
(true dead-*store* detection, as opposed to dead-*variable* detection, isn't
implemented — it would need real per-line liveness analysis). Also, a variable
read only inside a branch that later gets removed as dead-condition code is
still counted as "read" during analysis, so its declaration won't be flagged
dead even after that branch disappears — a minor, documented imprecision.
""")

st.write("---")

if 'show_editor' not in st.session_state:
    st.session_state.show_editor = False
if 'session_id' not in st.session_state:
    st.session_state.session_id = str(uuid.uuid4())

if st.button("Open C Programme Block 💻"):
    st.session_state.show_editor = not st.session_state.show_editor


@st.cache_resource(show_spinner=False)
def build_optimizer():
    """Compiles lexer.l + parser.y -> ./optimizer exactly once per running
    server, regardless of how many users hit the app or how many times a
    given user reruns the script. Returns (ok: bool, log: str)."""
    is_windows = platform.system() == "Windows"
    if is_windows:
        return True, "Windows host detected; expecting a prebuilt optimizer.exe."

    if os.path.exists("optimizer"):
        return True, "Using previously compiled binary."

    log = []
    steps = [
        ["bison", "-d", "parser.y"],
        ["flex", "lexer.l"],
        ["gcc", "lex.yy.c", "parser.tab.c", "-o", "optimizer"],
    ]
    for step in steps:
        proc = subprocess.run(step, capture_output=True, text=True)
        log.append(f"$ {' '.join(step)}\n{proc.stdout}{proc.stderr}")
        if proc.returncode != 0:
            return False, "\n".join(log)
    return True, "\n".join(log)


if st.session_state.show_editor:
    build_ok, build_log = build_optimizer()
    if not build_ok:
        st.error("The optimizer failed to compile. See the build log below.")
        st.code(build_log, language="text")
        st.stop()

    # Each browser session gets its own isolated input/output files so two
    # people running the tool at the same time never overwrite each other.
    work_dir = tempfile.gettempdir()
    input_path = os.path.join(work_dir, f"input_{st.session_state.session_id}.txt")
    output_path = os.path.join(work_dir, f"output_{st.session_state.session_id}.c")

    col1, col2 = st.columns(2)

    with col1:
        st.subheader("C Source Code")
        default_code = (
            "int add(int a, int b) {\n"
            "    return a + b;\n"
            "}\n\n"
            "int main() {\n"
            "    int active_var = 10;\n"
            "    int dead_var;\n"
            "    int sum = 10 + 20;\n"
            "    int total = 0;\n\n"
            "    for (int i = 0; i < active_var; i++) {\n"
            "        total += i;\n"
            "    }\n\n"
            "    if (0) {\n"
            "        printf(\"this branch is impossible\");\n"
            "    }\n\n"
            "    printf(\"%d\", total);\n"
            "    return 0;\n"
            "    printf(\"this line can never run\");\n"
            "}"
        )
        user_code = st.text_area("Editor", value=default_code, height=350, label_visibility="collapsed")
        run_btn = st.button("Run Optimizer ►", type="primary")

    with col2:
        st.subheader("Live Console Output")
        output_placeholder = st.empty()
        output_placeholder.info(">_ \n\nClick 'Run Optimizer' to start.")

    st.write("---")
    st.subheader("Final Optimized Source Code")
    final_code_placeholder = st.empty()
    final_code_placeholder.info("The cleaned C code will appear here after execution.")

    if run_btn:
        if user_code.strip() == "":
            output_placeholder.warning("Please enter some C code first.")
        else:
            with open(input_path, "w") as file:
                file.write(user_code)

            exec_name = "optimizer.exe" if platform.system() == "Windows" else "./optimizer"

            try:
                result = subprocess.run(
                    [exec_name, input_path, output_path],
                    capture_output=True,
                    text=True,
                    check=True,
                )

                console_log = result.stdout
                marker = "====================================================\nOPTIMIZED C SOURCE CODE"
                if marker in console_log:
                    console_log = console_log.split(marker)[0]

                output_placeholder.success("Execution Successful")
                output_placeholder.code(console_log.strip(), language="text")

                if os.path.exists(output_path):
                    with open(output_path, "r") as opt_file:
                        final_c_code = opt_file.read()
                    final_code_placeholder.code(final_c_code, language="c")
                else:
                    final_code_placeholder.error("Optimized output file was not generated.")

            except subprocess.CalledProcessError as e:
                output_placeholder.error(
                    "Your C code has a syntax the optimizer doesn't support yet "
                    "(or a genuine syntax error). See details below — check the "
                    "'What kind of C code does this tool understand?' box above "
                    "for the supported subset."
                )
                output_placeholder.code(e.stderr or "(no error output captured)", language="text")
            except FileNotFoundError:
                output_placeholder.error(f"{exec_name} not found. Compilation may have failed.")
