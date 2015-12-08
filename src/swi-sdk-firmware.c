#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

/* QMI SDK */
#include "SWIWWANCMAPI.h"
#include "qmerrno.h"

/* stolen from SampleApps/Firmware_Download/inc/fwDld_9x15.h */
#define IMG_FW_TYPE_CWE 2
#define IMG_PRI_TYPE_NVU 3
#define IMG_FW_TYPE_SPK 4

#define __stringify_1(x...)     #x
#define __stringify(x...)       __stringify_1(x)

/* builtin sdk binary location */
static char *sdkpath = __stringify(SDK_EXE);
char devmode;

void get_img_info(char *imgpath)
{
    CurrentImgList     CurrImgList;
    CurrImageInfo      currImgInfo[5];
    BYTE               numEntries  = 5;
    int i, ret;

    printf("bar\n");
    if (strlen(imgpath))
	    printf("foo\n");
    memset( (void *)&CurrImgList, 0, sizeof( CurrImgList ) );
    memset( (void *)&currImgInfo, 0, sizeof( currImgInfo ) );
    CurrImgList.pCurrImgInfo = currImgInfo;
    CurrImgList.numEntries   = numEntries;

    /* There are 2 possible scenario's determined by calling SLQSSwiGetFwCurr
     * 1) Device does not support Gobi IM - In this case use same procedure as
     *    FwDloader_9x00. In this case, we need only one file( spkg format).
     * 2) Device supports GIM but data returned is blank. Use normal procedure. */
    ret = SLQSSwiGetFirmwareCurr( &CurrImgList );

    printf("result: %d\n", ret);

    printf("%s %s %s %s\n", CurrImgList.priver,CurrImgList.pkgver,CurrImgList.fwvers,CurrImgList.carrier );

    for (i = 0; i < ret; i++) {
	    printf("%u %s %u %s\n", currImgInfo[i].imageType, currImgInfo[i].uniqueID, currImgInfo[i].buildIDLen, currImgInfo[i].buildID);
    }
  
}

typedef struct device_info {
	char node[256];
	char key[16];
} devinfo_t;

int start_sdk()
{
    int rc;
    unsigned char num = 3;
    struct device_info dev[3], *pdev;
    
    /* Set SDK image path */
    printf("setting sdk path to %s\n",  sdkpath);
    rc = SetSDKImagePath(sdkpath);
    if (rc)
	    return rc;

    /* Establish APP<->SDK IPC to first modem found */
    rc = SLQSStart(0, NULL);
    if (rc)
	    return rc;
    
    /* get the device mode */
    rc = SLQSGetDeviceMode((unsigned char *)&devmode);

    /* Can enumerate and connect only if device is in Application mode */
    if (devmode == DEVICE_STATE_READY) {
	    while (QCWWAN2kEnumerateDevices(&num, (unsigned char *)&dev[0])) {
		    printf("\nUnable to find device..\n");
		    sleep(1);
	    }
    }
    pdev = &dev[0];
    printf("node=%s,  key=%s\n", dev[0].node, dev[0].key);
    rc = QCWWANConnect(pdev->node, pdev->key);

    return rc;
}


int main(int argc, char *argv[])
{
	printf("argc=%d\n", argc);
	start_sdk();
	get_img_info(argv[1]);
	return 0;
}
