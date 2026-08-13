# 🚀 Dead Code Optimizer

A source-to-source compiler optimization tool built to analyze basic C programs, identify unused (dead) variables, perform constant folding, and generate clean, optimized source code. 

This project was developed as an academic submission for the **Compiler Design Lab** within the Computer Science and Engineering department at **Daffodil International University (Batch 67)**.

## ✨ Features
* **Dead Variable Elimination:** Scans the Symbol Table to detect variables that are declared but never used in any assignments or expressions, effectively removing them from the final code.
* **Constant Folding:** Evaluates mathematical expressions (including operations with parentheses) at compile-time rather than runtime (e.g., folding `10 + 20` directly into `30`).
* **Source-to-Source Generation:** Automatically rewrites the input C script, completely erasing the dead code lines and generating an `output_optimized.c` file.
* **Modern Web Interface:** A user-friendly, side-by-side IDE layout with a live console and syntax highlighting, built using Python and Streamlit.

## 🛠️ Tech Stack
* **Lexical & Syntax Analysis:** Flex (Lex) and Bison (Yacc)
* **Compiler Backend:** GCC (C)
* **Frontend/Web Server:** Python & Streamlit
* **Cloud Hosting:** Streamlit Community Cloud (Linux container)

## 📂 Repository Structure
* `lexer.l`: The Flex file containing regex rules to tokenize the C source code (ignoring comments and preprocessor directives).
* `parser.y`: The Bison file defining the grammar rules, handling the Abstract Syntax Tree (AST) evaluation, and managing the Symbol Table to track variable lifecycles.
* `app.py`: The Python Streamlit application that provides the web interface, dynamically compiles the C backend on the server, and routes the I/O.
* `packages.txt`: System-level dependency instructions ensuring the Streamlit Cloud Linux server installs GCC, Flex, and Bison before booting.

## 🌐 Live Demo
The project is hosted live on Streamlit Cloud. 
**Access the live application here: https://dead-code-optimizer-5ul2eedtgeadkobx6dvw5a.streamlit.app/   

## 💻 Local Testing
If you wish to run this tool locally on a Windows machine:
1. Ensure **MinGW (GCC)** and **GnuWin32 (Flex & Bison)** are installed and added to your system `PATH`.
2. Clone this repository.
3. Install the required Python library:
   ```bash
   pip install streamlit
   
