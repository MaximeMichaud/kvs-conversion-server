# kvs-conversion-server | Tested with 6.1.2 and 6.2.1

[![ShellCheck](https://github.com/MaximeMichaud/kvs-conversion-server/workflows/ShellCheck/badge.svg)](https://github.com/MaximeMichaud/kvs-conversion-server/actions?query=workflow%3AShellCheck)
[![made-with-bash](https://img.shields.io/badge/-Made%20with%20Bash-1f425f.svg?logo=image%2Fpng%3Bbase64%2CiVBORw0KGgoAAAANSUhEUgAAABgAAAAYCAYAAADgdz34AAAAGXRFWHRTb2Z0d2FyZQBBZG9iZSBJbWFnZVJlYWR5ccllPAAAAyZpVFh0WE1MOmNvbS5hZG9iZS54bXAAAAAAADw%2FeHBhY2tldCBiZWdpbj0i77u%2FIiBpZD0iVzVNME1wQ2VoaUh6cmVTek5UY3prYzlkIj8%2BIDx4OnhtcG1ldGEgeG1sbnM6eD0iYWRvYmU6bnM6bWV0YS8iIHg6eG1wdGs9IkFkb2JlIFhNUCBDb3JlIDUuNi1jMTExIDc5LjE1ODMyNSwgMjAxNS8wOS8xMC0wMToxMDoyMCAgICAgICAgIj4gPHJkZjpSREYgeG1sbnM6cmRmPSJodHRwOi8vd3d3LnczLm9yZy8xOTk5LzAyLzIyLXJkZi1zeW50YXgtbnMjIj4gPHJkZjpEZXNjcmlwdGlvbiByZGY6YWJvdXQ9IiIgeG1sbnM6eG1wPSJodHRwOi8vbnMuYWRvYmUuY29tL3hhcC8xLjAvIiB4bWxuczp4bXBNTT0iaHR0cDovL25zLmFkb2JlLmNvbS94YXAvMS4wL21tLyIgeG1sbnM6c3RSZWY9Imh0dHA6Ly9ucy5hZG9iZS5jb20veGFwLzEuMC9zVHlwZS9SZXNvdXJjZVJlZiMiIHhtcDpDcmVhdG9yVG9vbD0iQWRvYmUgUGhvdG9zaG9wIENDIDIwMTUgKFdpbmRvd3MpIiB4bXBNTTpJbnN0YW5jZUlEPSJ4bXAuaWlkOkE3MDg2QTAyQUZCMzExRTVBMkQxRDMzMkJDMUQ4RDk3IiB4bXBNTTpEb2N1bWVudElEPSJ4bXAuZGlkOkE3MDg2QTAzQUZCMzExRTVBMkQxRDMzMkJDMUQ4RDk3Ij4gPHhtcE1NOkRlcml2ZWRGcm9tIHN0UmVmOmluc3RhbmNlSUQ9InhtcC5paWQ6QTcwODZBMDBBRkIzMTFFNUEyRDFEMzMyQkMxRDhEOTciIHN0UmVmOmRvY3VtZW50SUQ9InhtcC5kaWQ6QTcwODZBMDFBRkIzMTFFNUEyRDFEMzMyQkMxRDhEOTciLz4gPC9yZGY6RGVzY3JpcHRpb24%2BIDwvcmRmOlJERj4gPC94OnhtcG1ldGE%2BIDw%2FeHBhY2tldCBlbmQ9InIiPz6lm45hAAADkklEQVR42qyVa0yTVxzGn7d9Wy03MS2ii8s%2BeokYNQSVhCzOjXZOFNF4jx%2BMRmPUMEUEqVG36jo2thizLSQSMd4N8ZoQ8RKjJtooaCpK6ZoCtRXKpRempbTv5ey83bhkAUphz8fznvP8znn%2B%2F3NeEEJgNBoRRSmz0ub%2FfuxEacBg%2FDmYtiCjgo5NG2mBXq%2BH5I1ogMRk9Zbd%2BQU2e1ML6VPLOyf5tvBQ8yT1lG10imxsABm7SLs898GTpyYynEzP60hO3trHDKvMigUwdeaceacqzp7nOI4n0SSIIjl36ao4Z356OV07fSQAk6xJ3XGg%2BLCr1d1OYlVHp4eUHPnerU79ZA%2F1kuv1JQMAg%2BE4O2P23EumF3VkvHprsZKMzKwbRUXFEyTvSIEmTVbrysp%2BWr8wfQHGK6WChVa3bKUmdWou%2BjpArdGkzZ41c1zG%2Fu5uGH4swzd561F%2BuhIT4%2BLnSuPsv9%2BJKIpjNr9dXYOyk7%2FBZrcjIT4eCnoKgedJP4BEqhG77E3NKP31FO7cfQA5K0dSYuLgz2TwCWJSOBzG6crzKK%2BohNfni%2Bx6OMUMMNe%2Fgf7ocbw0v0acKg6J8Ql0q%2BT%2FAXR5PNi5dz9c71upuQqCKFAD%2BYhrZLEAmpodaHO3Qy6TI3NhBpbrshGtOWKOSMYwYGQM8nJzoFJNxP2HjyIQho4PewK6hBktoDcUwtIln4PjOWzflQ%2Be5yl0yCCYgYikTclGlxadio%2BBQCSiW1UXoVGrKYwH4RgMrjU1HAB4vR6LzWYfFUCKxfS8Ftk5qxHoCUQAUkRJaSEokkV6Y%2F%2BJUOC4hn6A39NVXVBYeNP8piH6HeA4fPbpdBQV5KOx0QaL1YppX3Jgk0TwH2Vg6S3u%2BdB91%2B%2FpuNYPYFl5uP5V7ZqvsrX7jxqMXR6ff3gCQSTzFI0a1TX3wIs8ul%2Bq4HuWAAiM39vhOuR1O1fQ2gT%2F26Z8Z5vrl2OHi9OXZn995nLV9aFfS6UC9JeJPfuK0NBohWpCHMSAAsFe74WWP%2BvT25wtP9Bpob6uGqqyDnOtaeumjRu%2ByFu36VntK%2FPA5umTJeUtPWZSU9BCgud661odVp3DZtkc7AnYR33RRC708PrVi1larW7XwZIjLnd7R6SgSqWSNjU1B3F72pz5TZbXmX5vV81Yb7Lg7XT%2FUXriu8XLVqw6c6XqWnBKiiYU%2BMt3wWF7u7i91XlSEITwSAZ%2FCzAAHsJVbwXYFFEAAAAASUVORK5CYII%3D)](https://www.gnu.org/software/bash/)
[![GNU Licence](https://img.shields.io/badge/License-MIT-blue.svg)](https://github.com/MaximeMichaud/kvs-conversion-server/blob/main/LICENSE)

This script automates the setup and configuration of a Kernel Video Sharing (KVS) Conversion Server, ensuring **optimal performance** and **security** with minimal dependencies and **stable** LTS packages.

We strongly recommend all users to thoroughly read this README.md to fully understand the features, limitations, and development aspects of the script.


## Usage

```bash
bash <(curl -s https://raw.githubusercontent.com/MaximeMichaud/kvs-conversion-server/main/kvs-conversion-server.sh)
```

## Compatibility

- **Docker Dependency**: This script requires Docker to be installed and functioning on your system. Docker provides the necessary isolation and environment consistency to run the conversion software reliably. The script will automatically check if Docker is installed on your system. If it is not found, you will be prompted to install Docker using the official installation script. Please note that installing Docker may require virtualization to be enabled on your system and administrative (root) privileges to install the Docker package.

- **System Architecture**: The script and its dependencies have been tested exclusively on amd64 architectures. Ensure your system complies with this specification to guarantee compatibility.

- **CPU Only Testing**: This script has been tested with CPU-based processing only. We have not conducted tests with dedicated or integrated GPUs. If you are interested in exploring GPU-accelerated processing for video conversion, please open an issue on our GitHub repository to discuss your requirements and potential enhancements.


### Hardware Recommendations

To ensure optimal performance of the video conversion server, the following hardware specifications are recommended:

RAM: At least 1GB of RAM is recommended. This is generally sufficient for handling the operational overhead of Docker and the basic video processing tasks.
CPU: A faster CPU is crucial as video conversion is a CPU-intensive process. The speed and number of CPU cores will significantly influence the time required to process videos.
Storage: Sufficient storage space is necessary to accommodate the raw video files and the converted outputs. While an HDD is adequate for storage purposes, the processing capability primarily depends on the CPU power.

Please consider these recommendations as guidelines which reflect the minimum setup required to efficiently use the script and perform video conversions. 
The actual performance can vary based on the specific video formats and the conversion settings used.

## Features

- **Automated KVS Setup**: Installs all necessary dependencies and configures cron jobs, tailored to meet the [KVS requirements](https://www.kernel-video-sharing.com/en/requirements/). For more details on video conversion engines and speeds, see [Video Conversion Engine and Speed](https://forum.kernel-video-sharing.com/topic/50-video-conversion-engine-and-video-conversion-speed/). To learn how to add a remote conversion server in KVS, visit [Adding a Remote Conversion Server in KVS](https://forum.kernel-video-sharing.com/topic/118-how-to-add-remote-conversion-server-in-kvs/).
- **Extended PHP Support**: Uses Sury's repository to provide extended PHP version support, incorporating security updates from [Freexian's Debian LTS project](https://www.freexian.com/lts/debian/).
<!-- - **Automated Updates**: Enables automatic updates for all installed packages and added repositories to keep the server secure and up-to-date. -->
- **Container Configuration**: Provides the capability to limit CPU usage for Docker containers. This feature allows users to set custom limits on CPU utilization, tailored to their system's capabilities.

## To-Do

- **Optional IonCube Installation**: Add functionality to optionally install IonCube depending on the user's licensing needs. This will allow users to comply with software requirements that may require encoded PHP files.

- **Container Configuration**: Develop the ability to limit CPU usage for the Docker container. This will include user options to customize these limits based on their system capabilities and conversion needs.

- **Network Configuration**: Implement checks to determine if the outbound IPv4 configuration can open ports. Additionally, provide options to configure the server to operate solely on local networks if necessary to enhance security and compliance with internal network policies.

- **Tailscale Support for Restricted Environments**: Integrate Tailscale to ensure the conversion server operates effectively within private network environments. This approach simplifies connectivity without the complexities of traditional network configuration methods, enhancing secure access and interoperability across restrictive firewalls or network filters.

- **FFmpeg Version Selection**: Implement the option for users to select between different FFmpeg versions (5.x, 6.x, 7.x) depending on their specific requirements for video processing capabilities and compatibility with various codecs and formats.

- **Enabling SSL with vsftpd (FTPS)**: Provide the option to configure SSL for vsftpd to enhance security by enabling FTPS. This feature will allow encrypted file transfers, protecting data integrity and confidentiality during file uploads and downloads.

- **Unattended Upgrades**: Implement unattended upgrades to ensure that all packages, especially those from sury.org, are updated automatically. This will reduce maintenance overhead and improve security by keeping the system updated with the latest patches without user intervention.
 
View the full project details and progress [here](https://github.com/users/MaximeMichaud/projects/3).

## Supports

The technologies used depend on what KVS supports, which means that some may not be the most up-to-date if KVS has not yet provided support for them. (For example, PHP 8.2/8.3 is not yet officially supported by KVS and thus not recommended.)

* VsFTPd 3.0.5
* PHP 7.4 or PHP 8.1 (since 6.2.0) (with sury.org and IonCube)
* FFmpeg 7.1 (LTS)
* ImageMagick 7.x

## Customization and Limitations

While this script is designed for a straightforward deployment, it may require adjustments based on your server's Here are a few points to consider:

**Base Image**: The Docker image used in this script is based on `Debian 13 Slim`. This choice was made to balance flexibility and disk space usage. Although Debian Slim uses slightly more disk space compared to Alpine, it was selected over Alpine due to several key advantages:
  - **Compatibility Issues with Alpine**: Alpine Linux presented challenges that would have required additional configuration time and effort. Specifically, Alpine lacks support for certain libraries and tools needed for robust video processing.
  - **Support for Sury PHP**: Debian provides support for [sury.org](https://sury.org), a repository that offers updated PHP packages and patches for versions no longer officially supported by PHP.net. This is crucial for maintaining high security and compatibility standards in PHP-based applications, especially when dealing with video processing tasks where efficiency and reliability are paramount.

### Deployment Considerations / Scalability

- **Single Instance Recommended**: This script and the corresponding Docker image are not designed for operation across multiple instances simultaneously. To manage different workloads or multiple KVS installations, we recommend utilizing multiple directories rather than deploying multiple instances of the Docker image. This approach helps avoid resource contention and simplifies management.
**Network Requirements**: This image is optimized for use on open networks that are free of restrictive firewalls or filters. For environments within private networks or those subject to access restrictions, additional configuration steps may be required. Solutions like Tailscale or similar private network services can be utilized to facilitate necessary connectivity and ensure full functionality of the system.
- **Port Checking**: Currently, there is no automated check for open ports during the setup. If you encounter issues related to network limitations, manual adjustments may be necessary.
- **Headless Mode**: There is no headless mode available; you must use the script to proceed with installation. This manual interaction ensures proper setup and configuration according to the provided steps.
- **Kubernetes (K8S) Support**: At this time, Kubernetes deployment is not supported as it would require extensive modifications and specific interactions with the site utilizing the image. Future updates may address this capability depending on user needs and development resources.

These points should help you tailor the installation to your needs.

## Contributing

Contributions to the script are welcome! If you have improvements or bug fixes, please fork the repository and submit a pull request.