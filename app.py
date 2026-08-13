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
    # Top Section: Editor and Console
    col1, col2 = st.columns(2)
    
    with col1:
        st.subheader("C Source Code")
        default_code = "int main() {\n    int active_var = 10;\n    int dead_var;\n    \n    int sum = 10 + 20;\n    \n    return 0;\n}"
        user_code = st.text_area("Editor", value=default_code, height=350, label_visibility="collapsed")
        
        run_btn = st.button("Run Optimizer ►", type="primary")
        
    with col2:
        st.subheader("Live Console Output")
        output_placeholder = st.empty()
        output_placeholder.info(">_ \n\nClick 'Run Optimizer' to start.")
    
    # Bottom Section: The Final Source Code
    st.write("---")
    st.subheader("Final Optimized Source Code")
    final_code_placeholder = st.empty()
    final_code_placeholder.info("The cleaned C code will appear here after execution.")
        
    if run_btn:
        if user_code.strip() == "":
            output_placeholder.warning("Please enter some C code first.")
        else:
            # Save code to input.txt
            with open("input.txt", "w") as file:
                file.write(user_code)
            
            # --- CLOUD COMPATIBILITY LOGIC ---
            is_windows = platform.system() == "Windows"
            exec_name = "optimizer.exe" if is_windows else "./optimizer"
            
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
                
                # Clean up the console output (Hide the source code from the terminal)
                console_log = result.stdout
                if "OPTIMIZED C SOURCE CODE" in console_log:
                    console_log = console_log.split("====================================================\nOPTIMIZED C SOURCE CODE")[0]
                
                output_placeholder.success("Execution Successful")
                output_placeholder.code(console_log.strip(), language="text")
                
                # Fetch and display the final source code in the new section!
                if os.path.exists("output_optimized.c"):
                    with open("output_optimized.c", "r") as opt_file:
                        final_c_code = opt_file.read()
                    final_code_placeholder.code(final_c_code, language="c")
                else:
                    final_code_placeholder.error("output_optimized.c file was not generated.")
                
            except subprocess.CalledProcessError as e:
                output_placeholder.error("Compilation / Execution Error")
                output_placeholder.code(e.stderr, language="text")
            except FileNotFoundError:
                output_placeholder.error(f"{exec_name} not found. Compilation failed.")
