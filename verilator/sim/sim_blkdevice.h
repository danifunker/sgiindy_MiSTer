#pragma once
#include <iostream>
#include <fstream>
#include "verilated.h"
#include "sim_console.h"


#ifndef _MSC_VER
#else
#define WIN32
#endif

#define kVDNUM 10
#define kBLKSZ 512

struct SimBlockDevice {
public:

	IData* sd_lba[kVDNUM];
	CData* sd_rd;           // 2-bit in MacLC
	CData* sd_wr;           // 2-bit in MacLC
	CData* sd_ack;          // 2-bit in MacLC
	CData* sd_buff_addr;    // 8-bit for MacLC
	SData* sd_buff_dout;    // 16-bit for MacLC
	SData* sd_buff_din[kVDNUM];  // 16-bit for MacLC
	CData* sd_buff_wr;
	CData* img_mounted;     // 2-bit in MacLC
	CData* img_readonly;
	QData* img_size;

	int bytecnt;
        long int disk_size[kVDNUM];
	bool reading;
	bool writing;
	int ack_delay;
	int current_disk;
	bool mountQueue[kVDNUM];
	std::fstream disk[kVDNUM];

	void BeforeEval(int cycles);
	void AfterEval(void);
	//void QueueDownload(std::string file, int index);
	//void QueueDownload(std::string file, int index, bool restart);
	//bool HasQueue();
	void MountDisk( std::string file, int index);

	SimBlockDevice(DebugConsole c);
	~SimBlockDevice();


private:
	//std::queue<SimBus_DownloadChunk> downloadQueue;
	//SimBus_DownloadChunk currentDownload;
	//void SetDownload(std::string file, int index);
};
