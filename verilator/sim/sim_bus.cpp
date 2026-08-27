#include <iostream>
#include <queue>
#include <string>

#include "sim_bus.h"
#include "sim_console.h"

#ifndef _MSC_VER
#else
#define WIN32
#endif


static DebugConsole console;

FILE* ioctl_file = NULL;
int ioctl_next_addr = 0;
int ioctl_last_index = -1;

IData* ioctl_addr = NULL;
CData* ioctl_index = NULL;
CData* ioctl_wait = NULL;
CData* ioctl_download = NULL;
CData* ioctl_upload = NULL;
CData* ioctl_wr = NULL;
SData* ioctl_dout = NULL;  // 16-bit for MacLC
SData* ioctl_din = NULL;

std::queue<SimBus_DownloadChunk> downloadQueue;

void SimBus::QueueDownload(std::string file, int index) {
	SimBus_DownloadChunk chunk = SimBus_DownloadChunk(file, index);
	downloadQueue.push(chunk);
}
void SimBus::QueueDownload(std::string file, int index, bool restart) {
	SimBus_DownloadChunk chunk = SimBus_DownloadChunk(file, index, restart);
	downloadQueue.push(chunk);
}
bool SimBus::HasQueue() {
	return downloadQueue.size() > 0;
}

int nextword = 0;
int current_addr = 0;  // Address for current word being transferred

void SimBus::BeforeEval()
{
	// If no file is open and there is a download queued
	if (!ioctl_file && downloadQueue.size() > 0) {

		// Get chunk from queue
		currentDownload = downloadQueue.front();
		downloadQueue.pop();

		// If last index differs from this one then reset the addresses
		if (currentDownload.index != *ioctl_index) { ioctl_next_addr = 0; }
		// if we want to restart the ioctl_addr then reset it
		// leave it the same if we want to be able to load two roms sequentially
		if (currentDownload.restart) { ioctl_next_addr = 0; }
		// Set address and index
		*ioctl_addr = ioctl_next_addr;
		*ioctl_index = currentDownload.index;

		// Open file
		ioctl_file = fopen(currentDownload.file.c_str(), "rb");
		if (!ioctl_file) {
			console.AddLog("Cannot open file for download %s\n", currentDownload.file.c_str());
		}
		else {
			console.AddLog("Starting download: %s %d", currentDownload.file.c_str(), ioctl_next_addr, ioctl_next_addr);
		}
	}

	if (ioctl_file) {
		if (*ioctl_wait == 0) {
			*ioctl_download = 1;
			if (feof(ioctl_file)) {
				fclose(ioctl_file);
				ioctl_file = NULL;
				*ioctl_download = 0;
				*ioctl_wr = 0;
				console.AddLog("ioctl_download complete %d", ioctl_next_addr);
			}
			if (ioctl_file) {
				// Read 2 bytes for 16-bit ioctl_dout (MacLC)
				int byte1 = fgetc(ioctl_file);
				int byte2 = 0;
				if (feof(ioctl_file) == 0) {
					byte2 = fgetc(ioctl_file);
					if (feof(ioctl_file)) byte2 = 0;
					// Combine into 16-bit word (high byte first)
					nextword = (byte1 << 8) | (byte2 & 0xFF);
					// Set address and data BEFORE eval() - this is critical!
					// Must set these before ioctl_wr goes high so eval() sees correct values
					*ioctl_addr = ioctl_next_addr;
					*ioctl_dout = (unsigned short)nextword;
					*ioctl_wr = 1;
					ioctl_next_addr += 2;  // Byte address increments by 2 for each word
				}
			}
		}
	}
	else {
		*ioctl_download = 0;
		*ioctl_wr = 0;
	}
}

void SimBus::AfterEval()
{
	// Address and data are now set in BeforeEval before ioctl_wr goes high
	// This ensures eval() sees the correct values when it processes the write
}


SimBus::SimBus(DebugConsole c) {
	console = c;
	ioctl_addr = NULL;
	ioctl_index = NULL;
	ioctl_wait = NULL;
	ioctl_download = NULL;
	ioctl_upload = NULL;
	ioctl_wr = NULL;
	ioctl_dout = NULL;
	ioctl_din = NULL;
}

SimBus::~SimBus() {

}
