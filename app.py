import streamlit as st
import subprocess
import os
import platform

# Set page layout to 'wide'
st.set_page_config(page_title="Dead Code Optimizer", layout="wide")

st.title("Welcome to the Dead Code Optimizer")

st.markdown("""
### About This Project
This system is a Compiler Design Lab project designed to analyze basic C source code. 
It identifies and removes unnecessary statements or dead variables without altering the core logic. 
Developed as an academic submission for the Computer Science and Engineering department at Daffodil International University (Batch 67), this tool utilizes Flex/Lex and Bison/Yacc for lexical and syntax analysis.
""")

st.write("---")

if 'show_editor' not in st.session_state:
    st.session_state.show_editor = False

if st.button("Open C Programme Block 💻"):
    st.session_state.show_editor = not st.session_state.show_editor

if st.session_state.show_editor:
    col1, col2 = st.columns(2)
    
    with col1:
        st.subheader("C Source Code")
        default_code = "#include <stdio.h>\n\nint main() {\n    // Write your code here\n    \n    return 0;\n}"
        user_code = st.text_area("Editor", value=default_code, height=450, label_visibility="collapsed")
        
        run_btn = st.button("Run Optimizer ►", type="primary")
        
    with col2:
        st.subheader("Live Console Output")
        output_placeholder = st.empty()
        output_placeholder.info(">_ \n\nClick 'Run Optimizer' to start.")
        
        if run_btn:
            if user_code.strip() == "":
                output_placeholder.warning("Please enter some C code first.")
            else:
                # Save code to input.txt
                with open("input.txt", "w") as file:
                    file.write(user_code)
                
                # --- CLOUD COMPATIBILITY LOGIC ---
                # Check if we are on Windows or Linux
                is_windows = platform.system() == "Windows"
                exec_name = "optimizer.exe" if is_windows else "./optimizer"
                
                # If on Linux (Cloud) and the compiler hasn't run yet, build it!
                if not is_windows and not os.path.exists("optimizer"):
                    output_placeholder.info("Compiling C files on the cloud server... please wait.")
                    subprocess.run(["bison", "-d", "parser.y"])
                    subprocess.run(["flex", "lexer.l"])
                    subprocess.run(["gcc", "lex.yy.c", "parser.tab.c", "-o", "optimizer"])
                
                # --- RUN THE OPTIMIZER ---
                try:
                    result = subprocess.run(
                        [exec_name, "input.txt"], 
                        capture_output=True, 
                        text=True, 
                        check=True
                    )
                    output_placeholder.success("Execution Successful")
                    output_placeholder.code(result.stdout, language="text")
                    
                except subprocess.CalledProcessError as e:
                    output_placeholder.error("Compilation / Execution Error")
                    output_placeholder.code(e.stderr, language="text")
                except FileNotFoundError:
                    output_placeholder.error(f"{exec_name} not found. Compilation failed.")
