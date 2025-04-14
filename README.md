# 🚀 LLM Launcher

LLM Launcher is a Bash script for easily setting up and launching OpenWebUI with different Large Language Model (LLM) backends. This tool simplifies the process of connecting OpenWebUI to various LLM engines, helping users quickly deploy and test different language models with a single command.

**Optimized Environment:**
- **Operating System**: Linux
- **Hardware**: Intel processors with integrated GPU (especially Intel Core Ultra)

This script is specifically designed to leverage the hardware acceleration of Intel processors with integrated GPUs. While it may work on other configurations, options like LocalAI with SYCL acceleration and Ollama container are optimized for this hardware.

## 📑 Table of Contents
- [🔌 Supported Backends](#-supported-backends)
- [✅ Prerequisites](#-prerequisites)
- [📁 Directory Structure](#-directory-structure)
- [💻 Installation & Usage](#-installation--usage)
- [⚙️ Configuration Options](#️-configuration-options)
- [🛠️ How It Works](#️-how-it-works)
- [🔍 Troubleshooting](#-troubleshooting)
- [🖥️ Accessing the UI](#️-accessing-the-ui)
- [📝 License](#-license)
- [🙏 Acknowledgments](#-acknowledgments)

## 🔌 Supported Backends

The script supports the following LLM backends:

1. **Local Ollama**: Connects to an Ollama instance running on your local machine
2. **Remote LM Studio**: Connects to LM Studio running on another computer on your network
3. **Ollama in Docker container**: Runs Ollama in a container with Intel GPU support
4. **Local llama.cpp**: Connects to a local llama.cpp server with OpenAI-compatible API
5. **LocalAI with Intel acceleration**: Runs LocalAI in a container with Intel SYCL acceleration for optimal performance on Intel GPUs

## ✅ Prerequisites

Before using this script, you need to have the following installed:

- Docker (and Docker service running)
- Curl for connectivity testing
- One of the following text editors: nano, vim, vi (or set your $EDITOR environment variable)

Additionally, depending on your chosen backend:
- For option 1: Local Ollama installation
- For option 2: LM Studio running on a remote machine
- For option 3: No additional requirements (runs in Docker)
- For option 4: llama.cpp built and running with server support
- For option 5: Intel GPU drivers installed (optimal for Intel Core Ultra processors)

## 📁 Directory Structure

The script uses the following directory structure:

```
~/llm/
├── models/
│   ├── ollama/
│   ├── llama_cpp/
│   └── localai/
├── data/
│   └── open-webui/
└── logs/
```

## 💻 Installation & Usage

### Getting Started

1. Download the script:
   ```bash
   curl -O https://raw.githubusercontent.com/Issogr/llm-launcher/main/llm-launcher.sh
   chmod +x llm-launcher.sh
   ```

2. Run the script:
   ```bash
   ./llm-launcher.sh
   ```
   
The script will automatically:
- Check for required directories and create them if needed
- Create a default configuration file if none exists
- Guide you through selecting your preferred LLM backend
- Configure and launch OpenWebUI with the selected backend

### ⌨️ Command Line Options

For more control, you can use these optional parameters:

- `--help, -h`: Show help information
- `--setup-dirs`: Manually create the standard directories
- `--create-config`: Manually create or reset the default configuration file
- `--edit-config`: Open the configuration file in your default text editor

Example of advanced setup:
```bash
# First-time setup with manual configuration
./llm-launcher.sh --setup-dirs --create-config
./llm-launcher.sh --edit-config
./llm-launcher.sh
```

## ⚙️ Configuration Options

The configuration file (`~/llm/llm-launcher.conf`) contains several settings you can customize:

### 🔧 General Settings
- `DOCKER_NETWORK`: Name of the Docker network for container communication

### 🌐 OpenWebUI Settings
- `OPEN_WEBUI_IMAGE`: Docker image for OpenWebUI
- `OPEN_WEBUI_NAME`: Container name for OpenWebUI
- `OPEN_WEBUI_PORT`: Port for accessing OpenWebUI on your host

### 🐳 Ollama Container Settings
- `OLLAMA_CONTAINER_IMAGE`: Docker image for Ollama
- `OLLAMA_CONTAINER_NAME`: Container name for Ollama
- `MEMORY_LIMIT`: Memory limit for the Ollama container
- `SHM_SIZE`: Shared memory size for the Ollama container

### 📡 LM Studio Remote Settings
- `LM_STUDIO_HOST`: IP address of the remote machine running LM Studio
- `LM_STUDIO_PORT`: Port of the LM Studio API

### 🦙 llama.cpp Settings
- `LLAMA_CPP_HOST`: Host where llama.cpp is running
- `LLAMA_CPP_PORT`: Port of the llama.cpp server

### 🧠 LocalAI Settings
- `LOCALAI_IMAGE`: Docker image for LocalAI (with SYCL support for Intel GPUs)
- `LOCALAI_NAME`: Container name for LocalAI
- `LOCALAI_PORT`: Port for accessing LocalAI's API on your host
- `LOCALAI_MODEL`: Default model to load (e.g., "phi-2")
- `LOCALAI_EXTRA_FLAGS`: Additional flags to pass to LocalAI

## 🛠️ How It Works

The script follows these steps:

1. Checks prerequisites and loads the configuration
2. Creates a Docker network for container communication
3. Prompts for the desired backend type
4. Configures and verifies the selected backend
5. Pulls and starts the OpenWebUI container with appropriate settings
6. Verifies connectivity between OpenWebUI and the backend
7. Displays access information

## 🖥️ Accessing the UI

After running the script successfully, you can access OpenWebUI at:
```
http://localhost:[CONFIGURED_PORT]
```

The default port is 3000 unless you changed it in the configuration.

## 📝 License

This script is provided as open-source under MIT License.

## 🙏 Acknowledgments

This script relies on the following projects:
- [OpenWebUI](https://github.com/open-webui/open-webui)
- [Ollama](https://github.com/ollama/ollama)
- [LM Studio](https://lmstudio.ai/)
- [llama.cpp](https://github.com/ggerganov/llama.cpp)
- [LocalAI](https://github.com/go-skynet/LocalAI)