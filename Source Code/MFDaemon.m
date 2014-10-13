//
// Fan Control
// Copyright 2006 Lobotomo Software 
//
// This program is free software; you can redistribute it and/or
// modify it under the terms of the GNU General Public License
// as published by the Free Software Foundation; either version 2
// of the License, or (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with this program; if not, write to the Free Software
// Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301, USA.
//

#import "MFDaemon.h"

#import "MFProtocol.h"
#import "smc.h"

#define MFApplicationIdentifier     "com.lobotomo.MacProFan"

@implementation MFDaemon

static int cpu_b_failure = 0;

- (id)init
{
	if (self = [super init])
	{
		// set sane defaults
		lowerThreshold = 50.0;
		upperThreshold = 80.0;
		baseRpm = 400;
		maxRpm = 2800;
		
		lowerThreshold2 = 45.0;
		upperThreshold2 = 80.0;
		baseRpm2 = 800;
		maxRpm2 = 4000;
	}
	return self;
}

// store preferences
- (void)storePreferences
{
	CFPreferencesSetValue(CFSTR("baseRpm"), (CFPropertyListRef)@(baseRpm),
						  CFSTR(MFApplicationIdentifier), kCFPreferencesAnyUser, kCFPreferencesCurrentHost);
	CFPreferencesSetValue(CFSTR("lowerThreshold"), (CFPropertyListRef)@(lowerThreshold),
						  CFSTR(MFApplicationIdentifier), kCFPreferencesAnyUser, kCFPreferencesCurrentHost);
	CFPreferencesSetValue(CFSTR("upperThreshold"), (CFPropertyListRef)@(upperThreshold),
                          CFSTR(MFApplicationIdentifier), kCFPreferencesAnyUser, kCFPreferencesCurrentHost);
    
    
	CFPreferencesSetValue(CFSTR("baseRpm2"), (CFPropertyListRef)@(baseRpm2),
                          CFSTR(MFApplicationIdentifier), kCFPreferencesAnyUser, kCFPreferencesCurrentHost);
	CFPreferencesSetValue(CFSTR("lowerThreshold2"), (CFPropertyListRef)@(lowerThreshold2),
                          CFSTR(MFApplicationIdentifier), kCFPreferencesAnyUser, kCFPreferencesCurrentHost);
	CFPreferencesSetValue(CFSTR("upperThreshold2"), (CFPropertyListRef)@(upperThreshold2),
                          CFSTR(MFApplicationIdentifier), kCFPreferencesAnyUser, kCFPreferencesCurrentHost);
    
    
	CFPreferencesSetValue(CFSTR("fahrenheit"), (CFPropertyListRef)@(fahrenheit),
                          CFSTR(MFApplicationIdentifier), kCFPreferencesAnyUser, kCFPreferencesCurrentHost);
	CFPreferencesSynchronize(CFSTR(MFApplicationIdentifier), kCFPreferencesAnyUser, kCFPreferencesCurrentHost);
}

// read preferences
- (void)readPreferences
{
	baseRpm = [[self prefByKey:CFSTR("baseRpm")] intValue];
	lowerThreshold = [[self prefByKey:CFSTR("lowerThreshold")] floatValue];
	upperThreshold = [[self prefByKey:CFSTR("upperThreshold")] floatValue];

	baseRpm2 = [[self prefByKey:CFSTR("baseRpm2")] intValue];
	lowerThreshold2 = [[self prefByKey:CFSTR("lowerThreshold2")] floatValue];
	upperThreshold2 = [[self prefByKey:CFSTR("upperThreshold2")] floatValue];

	fahrenheit = [[self prefByKey:CFSTR("fahrenheit")] boolValue];
}

- (NSNumber *)prefByKey:(CFStringRef)key
{
	CFPropertyListRef property;

	property = CFPreferencesCopyValue(key, CFSTR(MFApplicationIdentifier), kCFPreferencesAnyUser, kCFPreferencesCurrentHost);

	if (property) {
		CFAutorelease(property);
		return (NSNumber *)property;
	}

	return nil;
}

// this gets called after application start
- (void)start
{
	[self readPreferences];
	NSTimer* myTimer = [NSTimer scheduledTimerWithTimeInterval:1.0 target:self selector:@selector(timer) userInfo:nil repeats:YES];
	[myTimer setTolerance:0.1];
}

// control loop called by NSTimer
- (void)timer
{
	double temp_io, temp_a, temp_b, temp_use;
	int targetRpm;
	int step;
	int step2;
	int targetRpm2;

	temp_b = 0;

	io_connect_t conn = 0;

	SMCOpen(&conn);

	temp_io = SMCGetTemperature(SMC_KEY_CPU_A_HS_TEMP, conn);
	temp_a = SMCGetTemperature(SMC_KEY_CPU_A_TEMP, conn);

	if (cpu_b_failure < 10)
	{
		temp_b = SMCGetTemperature(SMC_KEY_CPU_B_TEMP, conn);

		if (temp_b < 5)
			cpu_b_failure++;
	}

	//***** Intake and Exhaust Fan *****//
	if (temp_io < lowerThreshold)
	{
		targetRpm = baseRpm;
	}
	else if (temp_io > upperThreshold)
	{
		targetRpm = maxRpm;
	}
	else
	{
		targetRpm = baseRpm + (temp_io - lowerThreshold)*((maxRpm - baseRpm)/(upperThreshold - lowerThreshold));
	}

	// adjust fan speed in reasonable steps - no need to be too dynamic
	if (currentRpm == 0)
	{
		step = targetRpm;
	}
	else
	{
		step = (targetRpm - currentRpm) / 30;
	}

	if(temp_io<lowerThreshold && currentRpm+10<baseRpm+100 && currentRpm>baseRpm)
	{
		step = -5;
	}

	targetRpm = currentRpm = currentRpm + step;

	SMCSetFanRpm(SMC_KEY_INTAKE_RPM_MIN, targetRpm, conn);
	SMCSetFanRpm(SMC_KEY_EXHAUST_RPM_MIN, targetRpm, conn);

	temp_use = MAX(temp_a, temp_b);

	//***** CPU A Fan *****//
	if (temp_use < lowerThreshold2)
	{
		targetRpm2 = baseRpm2;
	}
	else if (temp_use > upperThreshold2)
	{
		targetRpm2 = maxRpm2;
	}
	else
	{
		targetRpm2 = baseRpm2 + (temp_use - lowerThreshold2)*((maxRpm2 - baseRpm2)/(upperThreshold2 - lowerThreshold2));
	}
	
	// adjust fan speed in reasonable steps - no need to be too dynamic
	if (currentRpm2 == 0)
	{
		step2 = targetRpm2;
	}
	else
	{
		step2 = (targetRpm2 - currentRpm2) / 30;
	}
	
	if(temp_a<lowerThreshold2 && currentRpm2+10<baseRpm2+100 && currentRpm2>baseRpm2)
	{
		step2 = -5;
	}

	targetRpm2 = currentRpm2 = currentRpm2 + step2;

	SMCSetFanRpm(SMC_KEY_CPU_A_RPM_MIN, targetRpm2, conn);

	if(cpu_b_failure < 10 && temp_b>5)
	{
		SMCSetFanRpm(SMC_KEY_CPU_B_RPM_MIN, targetRpm2, conn);
	}

	SMCClose(conn);

	// save preferences
	if (needWrite) {
		[self storePreferences];
		needWrite = NO;
	}
}

// accessors
- (int)baseRpm
{
    return baseRpm;
}

- (void)setBaseRpm:(int)newBaseRpm
{
    baseRpm = newBaseRpm;
    needWrite = YES;
}

- (float)lowerThreshold
{
    return lowerThreshold;
}

- (void)setLowerThreshold:(float)newLowerThreshold
{
    lowerThreshold = newLowerThreshold;
    needWrite = YES;
}

- (float)upperThreshold
{
    return upperThreshold;
}

- (void)setUpperThreshold:(float)newUpperThreshold
{
    upperThreshold = newUpperThreshold;
    needWrite = YES;
}

- (int)baseRpm2
{
    return baseRpm2;
}

- (void)setBaseRpm2:(int)newBaseRpm2
{
    baseRpm2 = newBaseRpm2;
    needWrite = YES;
}

- (float)lowerThreshold2
{
    return lowerThreshold2;
}

- (void)setLowerThreshold2:(float)newLowerThreshold2
{
    lowerThreshold2 = newLowerThreshold2;
    needWrite = YES;
}

- (float)upperThreshold2
{
    return upperThreshold2;
}

- (void)setUpperThreshold2:(float)newUpperThreshold2
{
    upperThreshold2 = newUpperThreshold2;
    needWrite = YES;
}

- (BOOL)fahrenheit
{
    return fahrenheit;
}

- (void)setFahrenheit:(BOOL)newFahrenheit
{
    fahrenheit = newFahrenheit;
    needWrite = YES;
}

- (void)CPU_A_temp:(float *)CPU_A_temp
	 CPU_A_HS_temp:(float *)CPU_A_HS_temp
		CPU_B_temp:(float *)CPU_B_temp
	 CPU_B_HS_temp:(float *)CPU_B_HS_temp
  Northbridge_temp:(float *)Northbridge_temp
Northbridge_HS_temp:(float *)Northbridge_HS_temp
	  IntakeFanRpm:(int *)IntakeFanRpm
	 CPU_A_Fan_RPM:(int *)CPU_A_Fan_RPM
	 CPU_B_Fan_RPM:(int *)CPU_B_Fan_RPM
	 ExhaustFanRpm:(int *)ExhaustFanRpm
Intake_Min_Fan_Speed:(int *)Intake_Min_Fan_Speed
CPU_A_Fan_Min_Speed:(int *)CPU_A_Fan_Min_Speed
CPU_B_Fan_Min_Speed:(int *)CPU_B_Fan_Min_Speed
	  Ambient_temp:(float *)Ambient_temp
{
	io_connect_t conn = NULL;

	SMCOpen(&conn);

	if (Ambient_temp)
		*Ambient_temp = SMCGetTemperature(SMC_KEY_AMBIENT_TEMP, conn);

	//***** Intake and Exhaust Stuff *****/
	if (IntakeFanRpm)
		*IntakeFanRpm = SMCGetFanRpm(SMC_KEY_INTAKE_RPM_CUR, conn);

	if (Intake_Min_Fan_Speed)
		*Intake_Min_Fan_Speed = SMCGetFanRpm(SMC_KEY_INTAKE_RPM_MIN, conn);

	if (ExhaustFanRpm)
		*ExhaustFanRpm = SMCGetFanRpm(SMC_KEY_EXHAUST_RPM_CUR, conn);

	if (Northbridge_temp)
		*Northbridge_temp = SMCGetTemperature(SMC_KEY_Northbridge_TEMP, conn);

	if (Northbridge_HS_temp)
		*Northbridge_HS_temp = SMCGetTemperature(SMC_KEY_Northbridge_HS_TEMP, conn);

	//***** CPU A Stuff *****//
	if (CPU_A_temp)
		*CPU_A_temp = SMCGetTemperature(SMC_KEY_CPU_A_TEMP, conn);

	if (CPU_A_HS_temp)
		*CPU_A_HS_temp = SMCGetTemperature(SMC_KEY_CPU_A_HS_TEMP, conn);

	if (CPU_A_Fan_RPM)
		*CPU_A_Fan_RPM = SMCGetFanRpm(SMC_KEY_CPU_A_RPM_CUR, conn);

	if (CPU_A_Fan_Min_Speed)
		*CPU_A_Fan_Min_Speed = SMCGetFanRpm(SMC_KEY_CPU_A_RPM_MIN, conn);

	//***** CPU B Stuff *****//
	if(cpu_b_failure < 10)
	{
		if (CPU_B_temp)
			*CPU_B_temp = SMCGetTemperature(SMC_KEY_CPU_B_TEMP, conn);

		if (CPU_B_HS_temp)
			*CPU_B_HS_temp = SMCGetTemperature(SMC_KEY_CPU_B_HS_TEMP, conn);

		if (CPU_B_Fan_RPM)
			*CPU_B_Fan_RPM = SMCGetFanRpm(SMC_KEY_CPU_B_RPM_CUR, conn);

		if (CPU_B_Fan_Min_Speed)
			*CPU_B_Fan_Min_Speed = SMCGetFanRpm(SMC_KEY_CPU_B_RPM_MIN, conn);
	}

	SMCClose(conn);
}

@end
