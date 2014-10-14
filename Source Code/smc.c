/*
 * Apple System Management Control (SMC) Tool
 * Copyright (C) 2006 devnull
 *
 * This program is free software; you can redistribute it and/or
 * modify it under the terms of the GNU General Public License
 * as published by the Free Software Foundation; either version 2
 * of the License, or (at your option) any later version.

 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.

 * You should have received a copy of the GNU General Public License
 * along with this program; if not, write to the Free Software
 * Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301, USA.
 */

#include <unistd.h>
#include <stdio.h>
#include <string.h>
#include <IOKit/IOKitLib.h>
#include <libkern/OSAtomic.h>

#include "smc.h"

// Cache the keyInfo to lower the energy impact of SMCReadKey()
#define KEY_INFO_CACHE_SIZE 100
struct {
	UInt32 key;
	SMCKeyData_keyInfo_t keyInfo;
} g_keyInfoCache[KEY_INFO_CACHE_SIZE];

int g_keyInfoCacheCount = 0;
OSSpinLock g_keyInfoSpinLock = 0;

UInt32 _strtoul(char *str, int size, int base)
{
	UInt32 total = 0;
	int i;

	for (i = 0; i < size; i++)
	{
		if (base == 16)
			total += str[i] << (size - 1 - i) * 8;
		else
			total += (unsigned char) (str[i] << (size - 1 - i) * 8);
	}
	return total;
}

void _ultostr(char *str, UInt32 val)
{
	str[0] = '\0';
	sprintf(str, "%c%c%c%c",
			(unsigned int) val >> 24,
			(unsigned int) val >> 16,
			(unsigned int) val >> 8,
			(unsigned int) val);
}

float _strtof(char *str, int size, int e)
{
	float total = 0;
	int i;

	for (i = 0; i < size; i++)
	{
		if (i == (size - 1))
			total += (str[i] & 0xff) >> e;
		else
			total += str[i] << (size - 1 - i) * (8 - e);
	}

	return total;
}

kern_return_t SMCOpen(io_connect_t *conn)
{
	kern_return_t result;
	mach_port_t   masterPort;
	io_iterator_t iterator;
	io_object_t   device;

	result = IOMasterPort(MACH_PORT_NULL, &masterPort);
	if (result != kIOReturnSuccess)
	{
		printf("Error: IOMasterPort() = %08x\n", result);
		return 1;
	}

	CFMutableDictionaryRef matchingDictionary = IOServiceMatching("AppleSMC");
	result = IOServiceGetMatchingServices(masterPort, matchingDictionary, &iterator);
	if (result != kIOReturnSuccess)
	{
		printf("Error: IOServiceGetMatchingServices() = %08x\n", result);
		return 1;
	}

	device = IOIteratorNext(iterator);
	IOObjectRelease(iterator);
	if (device == 0)
	{
		printf("Error: no SMC found\n");
		return 1;
	}

	result = IOServiceOpen(device, mach_task_self(), 0, conn);
	IOObjectRelease(device);
	if (result != kIOReturnSuccess)
	{
		printf("Error: IOServiceOpen() = %08x\n", result);
		return 1;
	}

	return kIOReturnSuccess;
}

kern_return_t SMCClose(io_connect_t conn)
{
	return IOServiceClose(conn);
}

kern_return_t SMCCall(int index, SMCKeyData_t *inputStructure, SMCKeyData_t *outputStructure, io_connect_t conn)
{
	size_t   structureInputSize;
	size_t   structureOutputSize;
	structureInputSize = sizeof(SMCKeyData_t);
	structureOutputSize = sizeof(SMCKeyData_t);

	return IOConnectCallStructMethod(conn, index, inputStructure, structureInputSize, outputStructure, &structureOutputSize);
}

// Provides key info, using a cache to dramatically improve the energy impact of smcFanControl
kern_return_t SMCGetKeyInfo(UInt32 key, SMCKeyData_keyInfo_t* keyInfo, io_connect_t conn)
{
	SMCKeyData_t inputStructure;
	SMCKeyData_t outputStructure;
	kern_return_t result = kIOReturnSuccess;
	int i = 0;

	OSSpinLockLock(&g_keyInfoSpinLock);

	for (; i < g_keyInfoCacheCount; ++i)
	{
		if (key == g_keyInfoCache[i].key)
		{
			*keyInfo = g_keyInfoCache[i].keyInfo;
			break;
		}
	}

	if (i == g_keyInfoCacheCount)
	{
		// Not in cache, must look it up.
		memset(&inputStructure, 0, sizeof(inputStructure));
		memset(&outputStructure, 0, sizeof(outputStructure));

		inputStructure.key = key;
		inputStructure.data8 = SMC_CMD_READ_KEYINFO;

		result = SMCCall(KERNEL_INDEX_SMC, &inputStructure, &outputStructure, conn);
		if (result == kIOReturnSuccess)
		{
			*keyInfo = outputStructure.keyInfo;
			if (g_keyInfoCacheCount < KEY_INFO_CACHE_SIZE)
			{
				g_keyInfoCache[g_keyInfoCacheCount].key = key;
				g_keyInfoCache[g_keyInfoCacheCount].keyInfo = outputStructure.keyInfo;
				++g_keyInfoCacheCount;
			}
		}
	}

	OSSpinLockUnlock(&g_keyInfoSpinLock);

	return result;
}

kern_return_t SMCReadKey(UInt32Char_t key, SMCVal_t *val,io_connect_t conn)
{
	kern_return_t result;
	SMCKeyData_t  inputStructure;
	SMCKeyData_t  outputStructure;

	memset(&inputStructure, 0, sizeof(SMCKeyData_t));
	memset(&outputStructure, 0, sizeof(SMCKeyData_t));
	memset(val, 0, sizeof(SMCVal_t));

	inputStructure.key = _strtoul(key, 4, 16);
	strcpy(val->key, key);

	result = SMCGetKeyInfo(inputStructure.key, &outputStructure.keyInfo, conn);
	if (result != kIOReturnSuccess)
	{
		return result;
	}

	val->dataSize = outputStructure.keyInfo.dataSize;
	_ultostr(val->dataType, outputStructure.keyInfo.dataType);
	inputStructure.keyInfo.dataSize = val->dataSize;
	inputStructure.data8 = SMC_CMD_READ_BYTES;

	result = SMCCall(KERNEL_INDEX_SMC, &inputStructure, &outputStructure, conn);
	if (result != kIOReturnSuccess)
	{
		return result;
	}

	memcpy(val->bytes, outputStructure.bytes, sizeof(outputStructure.bytes));

	return kIOReturnSuccess;
}

kern_return_t SMCWriteKey(SMCVal_t writeVal, io_connect_t conn)
{
	kern_return_t result;
	SMCKeyData_t  inputStructure;
	SMCKeyData_t  outputStructure;

	SMCVal_t      readVal;

	result = SMCReadKey(writeVal.key, &readVal, conn);
	if (result != kIOReturnSuccess)
		return result;

	if (readVal.dataSize != writeVal.dataSize)
		return kIOReturnError;

	memset(&inputStructure, 0, sizeof(SMCKeyData_t));
	memset(&outputStructure, 0, sizeof(SMCKeyData_t));

	inputStructure.key = _strtoul(writeVal.key, 4, 16);
	inputStructure.data8 = SMC_CMD_WRITE_BYTES;
	inputStructure.keyInfo.dataSize = writeVal.dataSize;
	memcpy(inputStructure.bytes, writeVal.bytes, sizeof(writeVal.bytes));

	return SMCCall(KERNEL_INDEX_SMC, &inputStructure, &outputStructure, conn);
}

double SMCGetTemperature(char *key, io_connect_t conn)
{
	SMCVal_t val;
	kern_return_t result;

	result = SMCReadKey(key, &val, conn);
	if (result == kIOReturnSuccess)
	{
		// read succeeded - check returned value
		if (val.dataSize > 1)
		{
			if (strcmp(val.dataType, DATATYPE_SP78) == 0)
			{
				// convert fp78 value to temperature
				int intValue = (val.bytes[0] * 256 + val.bytes[1]) >> 2;
				return intValue / 64.0;
			}
		}
	}
	// read failed
	return 0.0;
}

kern_return_t SMCSetFanRpm(char *key, int rpm, io_connect_t conn)
{
	SMCVal_t val;

	strcpy(val.key, key);
	val.bytes[0] = (rpm << 2) / 256;
	val.bytes[1] = (rpm << 2) % 256;
	val.dataSize = 2;

	return SMCWriteKey(val, conn);
}

int SMCGetFanRpm(char *key, io_connect_t conn)
{
	SMCVal_t val;
	kern_return_t result;

	result = SMCReadKey(key, &val, conn);
	if (result == kIOReturnSuccess)
	{
		// read succeeded - check returned value
		if (val.dataSize > 1)
		{
			if (strcmp(val.dataType, DATATYPE_FPE2) == 0)
			{
				// convert FPE2 value to int value
				return (int)_strtof(val.bytes, val.dataSize, 2);
			}
		}
	}
	// read failed
	return -1;
}
