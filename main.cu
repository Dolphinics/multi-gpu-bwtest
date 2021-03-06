#include <cuda.h>
#include <getopt.h>
#include <string>
#include <cstdlib>
#include <cstring>
#include <strings.h>
#include <cstdio>
#include <vector>
#include <exception>
#include <stdexcept>
#include "buffer.h"
#include "bench.h"
#include "timer.h"
#include "stream.h"
#include "device.h"

using namespace std;


static void showUsage(const char* fname)
{
    fprintf(stderr, 
            "Usage: %s [--do=<transfer specs>...] [--streams=<mode>]\n" 
            "\nDescription\n"
            "    This program uses multiple CUDA streams in an attempt at optimizing data\n"
            "    transfers between host and multiple CUDA devices using cudaMemcpyAsync().\n"
            "\nProgram options\n"
            "  --do=<transfer specs>    transfer specification\n"
            "  --streams=<mode>         stream modes for transfers\n"
            "  --list                   list available CUDA devices and quit\n"
            "  --help                   show this help text and quit\n"
            "\nStream modes\n"
            "  per-transfer             one stream per transfer [default]\n"
            "  per-device               transfers to the same device share streams\n"
            "  only-one                 all transfers share the same single stream\n"
            "\nTransfer specification format\n"
            "       <device>[:<direction>][:<size>][:<memory options>...]\n"
            "\nTransfer specification arguments\n"
            "  <device>                 CUDA device to use for transfer\n"
            "  <direction>              transfer directions\n"
            "  <size>                   transfer size in bytes [default is 32 MiB]\n"
            "  <memory options>         memory allocation options\n"
            "\nTransfer directions\n"
            "  HtoD                     host to device transfer (RAM to GPU)\n"
            "  DtoH                     device to host transfer (GPU to RAM)\n"
            "  both                     first HtoD then DtoH [default]\n"
            "  reverse                  first DtoH then HtoD\n"
            "\nMemory options format\n"
            "       option1,option2,option3,...\n"
            "\nMemory options\n"
            "  mapped                   map host memory into CUDA address space\n"
            //"  portable                 make host memory available in all contexts\n"
            "  wc                       allocate write-combined memory on the host\n"
            //"  managed                  allocate managed memory on the device\n"
            "\n"
            ,
            fname
           );
}


static void listDevices()
{
    const int deviceCount = countDevices();

    fprintf(stderr, "\n %2s   %-15s   %-9s   %7s   %7s   %7s   %8s   %2s\n",
            "ID", "Device name", "IO addr", "Compute", "Managed", "Unified", "Mappable", "#");
    fprintf(stderr, "-------------------------------------------------------------------------------\n");
    for (int i = 0; i < deviceCount; ++i)
    {
        cudaDeviceProp prop;
        loadDeviceProperties(i, prop);

        if (isDeviceValid(i))
        {
            fprintf(stderr, " %2d   %-15s   %02x:%02x.%-3x   %4d.%-2d   %7s   %7s   %8s   %2d\n",
                    i, prop.name, prop.pciBusID, prop.pciDeviceID, prop.pciDomainID,
                    prop.major, prop.minor, 
                    prop.managedMemory ? "yes" : "no", 
                    prop.unifiedAddressing ? "yes" : "no",
                    prop.canMapHostMemory ? "yes" : "no",
                    prop.asyncEngineCount);
        }
    }
    fprintf(stderr, "\n");
}


static void parseDevice(vector<int>& devices, const char* token)
{
    if (strcasecmp("all", token) != 0)
    {
        char* strptr = NULL;
        int device = strtol(token, &strptr, 10);
        if (strptr == NULL || *strptr != '\0' || !isDeviceValid(device))
        {
            fprintf(stderr, "Invalid transfer specification: '%s' is not a valid device\n", token);
            throw 3;
        }
        devices.push_back(device);

        cudaDeviceProp prop;
        loadDeviceProperties(device, prop);
        if (prop.major < 3 || (prop.major == 3 && prop.minor < 5))
        {
            fprintf(stderr, "WARNING: Compute capability of device %d is lower than 3.5\n", device);
        }
    }
    else
    {
        const int deviceCount = countDevices();

        for (int device = 0; device < deviceCount; ++device)
        {
            if (isDeviceValid(device))
            {
                devices.push_back(device);
            }

            cudaDeviceProp prop;
            loadDeviceProperties(device, prop);
            if (prop.major < 3 || (prop.major == 3 && prop.minor < 5))
            {
                fprintf(stderr, "WARNING: Compute capability of device %d is lower than 3.5\n", device);
            }
        }
    }
}


static void parseDirection(vector<cudaMemcpyKind>& directions, const char* token)
{
    if (strcasecmp("dtoh", token) == 0)
    {
        directions.push_back(cudaMemcpyDeviceToHost);
    }
    else if (strcasecmp("htod", token) == 0)
    {
        directions.push_back(cudaMemcpyHostToDevice);
    }
    else if (strcasecmp("both", token) == 0)
    {
        directions.push_back(cudaMemcpyHostToDevice);
        directions.push_back(cudaMemcpyDeviceToHost);
    }
    else if (strcasecmp("reverse", token) == 0)
    {
        directions.push_back(cudaMemcpyDeviceToHost);
        directions.push_back(cudaMemcpyHostToDevice);
    }
}


static void parseSize(size_t& size, const char* token)
{
    char* strptr = NULL;
    size = strtoul(token, &strptr, 0);
    if (strptr == NULL || *strptr != '\0')
    {
        size = 0;
    }
}


static void parseTransferSpecification(vector<TransferSpec>& transferSpecs, char* specStr)
{
    vector<int> devices;
    vector<cudaMemcpyKind> directions;
    size_t size = 0;

    unsigned int hostAllocFlags = cudaHostAllocDefault;
//    unsigned int deviceAllocFlags = 0;
//    bool useManagedDeviceMem = false;

    // First token must be device
    const char* delim = ":,";
    char* token = strtok(specStr, delim);
    parseDevice(devices, token);

    // The remaining of the transfer specification may be in arbitrary order
    // because we want to be nice
    while ((token = strtok(NULL, delim)) != NULL)
    {
        if (directions.empty())
        {
            parseDirection(directions, token);
        }

        if (strcasecmp("mapped", token) == 0)
        {
            hostAllocFlags |= cudaHostAllocMapped;
        }
        else if (strcasecmp("write-combined", token) == 0 || strcasecmp("wc", token) == 0)
        {
            hostAllocFlags |= cudaHostAllocWriteCombined;
        }
//        else if (strcasecmp("managed", token) == 0)
//        {
//            useManagedDeviceMem = true;
//        }

        if (size == 0)
        {
            parseSize(size, token);
        }
    }

    // Insert default values if necessary
    if (directions.empty())
    {
        directions.push_back(cudaMemcpyHostToDevice);
        directions.push_back(cudaMemcpyDeviceToHost);
    }
    if (size == 0)
    {
        size = 32 << 20;
    }

    // Try to allocate buffers and create transfer specification
    try
    {
        fprintf(stdout, "Allocating buffers...........");
        fflush(stdout);

        for (cudaMemcpyKind transferMode : directions)
        {
            for (int device : devices)
            {
                TransferSpec spec;
                spec.device = device;
                spec.deviceBuffer = createDeviceBuffer(device, size); // FIXME: Managed memory
                spec.hostBuffer = createHostBuffer(size, hostAllocFlags);
                spec.length = size;
                spec.direction = transferMode;

                transferSpecs.push_back(spec);
            }
        }

        fprintf(stdout, "DONE\n");
        fflush(stdout);
    }
    catch (const runtime_error& e)
    {
        fprintf(stdout, "FAIL\n");
        fflush(stdout);
        throw e;
    }
}


static void parseArguments(int argc, char** argv, StreamSharingMode& streamMode, vector<TransferSpec>& transferSpecs)
{
    // Define program arguments
    const option opts[] = {
        { .name = "transfer", .has_arg = 1, .flag = NULL, .val = 't' },
        { .name = "run", .has_arg = 1, .flag = NULL, .val = 't' },
        { .name = "do", .has_arg = 1, .flag = NULL, .val = 't' },
        { .name = "streams", .has_arg = 1, .flag = NULL, .val = 's' },
        { .name = "list", .has_arg = 0, .flag = NULL, .val = 'l' },
        { .name = "help", .has_arg = 0, .flag = NULL, .val = 'h' },
        { .name = NULL, .has_arg = 0, .flag = NULL, .val = 0 }
    };

    // Parse arguments
    int opt, idx;
    while ((opt = getopt_long(argc, argv, "-:t:s:lh", opts, &idx)) != -1)
    {
        switch (opt)
        {
            case ':': // missing value
                fprintf(stderr, "Option %s requires a value\n", argv[optind-1]);
                throw 1;

            case '?': // unknown option
                fprintf(stderr, "Unknown option: %s\n", argv[optind-1]);
                throw 1;

            case 't': // transfer specification
                parseTransferSpecification(transferSpecs, optarg);
                break;

            case 's': // stream sharing mode
                if (strcasecmp("per-transfer", optarg) == 0)
                {
                    streamMode = perTransfer;
                }
                else if (strcasecmp("per-device", optarg) == 0 || strcasecmp("per-gpu", optarg) == 0)
                {
                    streamMode = perDevice;
                }
                else if (strcasecmp("only-one", optarg) == 0 || strcasecmp("single", optarg) == 0)
                {
                    streamMode = singleStream;
                }
                else
                {
                    fprintf(stderr, "Unknown stream mode: %s\n", optarg);
                    throw 2;
                }
                break;

            case 'l': // list devices
                listDevices();
                throw 0;

            case 'h': // show help
                showUsage(argv[0]);
                throw 0;
        }
    }
}


int main(int argc, char** argv)
{
    StreamSharingMode streamMode = perTransfer;
    vector<TransferSpec> transferSpecs;

    // Parse program arguments
    try 
    {
        parseArguments(argc, argv, streamMode, transferSpecs);
    }
    catch (const runtime_error& e)
    {
        fprintf(stderr, "Unexpected error: %s\n", e.what());
        return 1;
    }
    catch (const int e) 
    {
        return e;
    }

    StreamManager streamManager(streamMode);

    try
    {
        // No transfer specifications?
        if (transferSpecs.empty())
        {
            char buffer[64];
            snprintf(buffer, sizeof(buffer), "all");
            parseTransferSpecification(transferSpecs, buffer);
        }

        // Create streams and timing events
        for (TransferSpec& spec : transferSpecs)
        {
            spec.stream = streamManager.retrieveStream(spec.device);
            spec.timer = createTimer();
        }

        // Run bandwidth test
        runBandwidthTest(transferSpecs);
    }
    catch (const runtime_error& e)
    {
        fprintf(stderr, "Unexpected error: %s\n", e.what());
        return 1;
    }

    return 0;
}
