#include "Utilties.h"
#include <mach/mach.h>
#include <dlfcn.h>
#include <mach-o/dyld_images.h>
#include <stdio.h>
#include "crossproc.h"

// ===================== 偏移集中区（新增） =====================
namespace OFFSET
{
    // ===== 基址 =====
    const long GWorld = 0x1338ED90;      // HTML版本
    const long ViewPort = 0x12DFB130;    // 矩阵入口

    // ===== Actor =====
    const long ActorArray = 0x60;
    const long ActorCount = 0x7C;

    const long Team = 0x5C;              // 阵营
    const long HeroID = 0x50;            // 英雄ID

    // ===== 血量 =====
    const long HPBase = 0x188;
    const long HP = 0xA8;
    const long HPMax = 0xB0;

    // ===== 坐标 =====
    const long Pos_1 = 0x268;
    const long Pos_2 = 0x10;
    const long Pos_3 = 0x0;
    const long Pos_4 = 0x60;

    // ===== 矩阵 =====
    const long Matrix_1 = 0xB8;
    const long Matrix_2 = 0x0;
    const long Matrix_3 = 0x8;
    const long Matrix_Final = 0x128;
}
// ===========================================================

long Imageaddress,Game_Data,Game_Viewport;
Matrix ViewMatrix;

static mach_port_t task;

// ===================== 基础读写 =====================
static bool Read_Data(long Src,int Size,void* Dst)
{
    vm_size_t size = 0;
    return vm_read_overwrite(task,(vm_address_t)Src,Size,(vm_address_t)Dst,&size)==KERN_SUCCESS;
}

static long Read_Long(long src){ long v=0; Read_Data(src,8,&v); return v; }
static int Read_Int(long src){ int v=0; Read_Data(src,4,&v); return v; }
static float Read_Float(long src){ float v=0; Read_Data(src,4,&v); return v; }

// ===================== 进程 & 模块 =====================
static int get_processes_pid()
{
    static int PID;
    size_t length = 0;
    int mib[] = {CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0};

    sysctl(mib, 4, NULL, &length, NULL, 0);
    struct kinfo_proc *procBuffer = (struct kinfo_proc *)malloc(length);
    if (!procBuffer) return 0;

    sysctl(mib, 4, procBuffer, &length, NULL, 0);
    int count = (int)(length / sizeof(struct kinfo_proc));

    for (int i = 0; i < count; i++) {
        NSString *name = [NSString stringWithUTF8String:procBuffer[i].kp_proc.p_comm];
        if ([name containsString:@"smoba"]) {
            task_for_pid(mach_task_self(), procBuffer[i].kp_proc.p_pid, &task);
            PID = procBuffer[i].kp_proc.p_pid;
            break;
        }
    }

    free(procBuffer);
    return PID;
}

static long get_module_base()
{
    get_processes_pid();

    task_dyld_info_data_t info = {};
    mach_msg_type_number_t count = TASK_DYLD_INFO_COUNT;
    if (task_info(task, TASK_DYLD_INFO, (task_info_t)&info, &count) != KERN_SUCCESS) {
        return 0;
    }

    dyld_all_image_infos aii = {};
    mach_vm_size_t size = sizeof(aii);
    if (mach_vm_read_overwrite(task, (mach_vm_address_t)info.all_image_info_addr, size, (mach_vm_address_t)&aii, &size) != KERN_SUCCESS) {
        return 0;
    }

    if (aii.infoArrayCount <= 0 || aii.infoArray == 0) {
        return 0;
    }

    auto *list = (dyld_image_info *)calloc((size_t)aii.infoArrayCount, sizeof(dyld_image_info));
    if (!list) return 0;

    mach_vm_size_t arraySize = (mach_vm_size_t)(aii.infoArrayCount * sizeof(dyld_image_info));
    if (mach_vm_read_overwrite(task, (mach_vm_address_t)aii.infoArray, arraySize, (mach_vm_address_t)list, &arraySize) != KERN_SUCCESS) {
        free(list);
        return 0;
    }

    for (int i = 0; i < aii.infoArrayCount; i++) {
        char path[1024] = {0};
        mach_vm_size_t out = 0;
        if (list[i].imageFilePath) {
            mach_vm_read_overwrite(task, (mach_vm_address_t)list[i].imageFilePath, sizeof(path) - 1, (mach_vm_address_t)path, &out);
        }

        NSString *name = [NSString stringWithUTF8String:path];
        if ([name containsString:@"UnityFramework"]) {
            long base = (long)list[i].imageLoadAddress;
            free(list);
            return base;
        }
    }

    free(list);
    return 0;
}

// ===================== 坐标 =====================
static float MemPosx,MemPosy;

static Vector2 GetPlayerPos(long Target)
{
    // ===== 新坐标链（HTML）=====
    long p1 = Read_Long(Target + OFFSET::Pos_1); // ★修改
    long p2 = Read_Long(p1 + OFFSET::Pos_2);
    long p3 = Read_Long(p2 + OFFSET::Pos_3);
    long p4 = Read_Long(p3 + OFFSET::Pos_4);

    int x = Read_Int(p4 + 0x0);
    int y = Read_Int(p4 + 0x8);

    if (x == 0) return {MemPosx,MemPosy};

    MemPosx = x / 1000.0f;
    MemPosy = y / 1000.0f;

    return {MemPosx,MemPosy};
}

// ===================== 阵营 =====================
static int GetPlayerTeam(long Target)
{
    return Read_Int(Target + OFFSET::Team); // ★修改
}

// ===================== 英雄ID =====================
static int GetPlayerHero(long Target)
{
    return Read_Int(Target + OFFSET::HeroID); // ★修改
}

// ===================== 血量 =====================
static float GetPlayerHeroHp(long Target)
{
    long hpBase = Read_Long(Target + OFFSET::HPBase); // ★修改

    int hp = Read_Int(hpBase + OFFSET::HP);
    int max = Read_Int(hpBase + OFFSET::HPMax);

    if (hp <= 0 || max <= 0) return 0;
    return (float)hp / max;
}

// ===================== 玩家 =====================
void GetPlayers(std::vector<SmobaHeroData> *Players)
{
    Players->clear();

    // ===== 新GWorld =====
    long GWorld = Read_Long(Imageaddress + OFFSET::GWorld); // ★修改

    if (GWorld < Imageaddress) return;

    long Level = Read_Long(GWorld + 0x138); // HTML结构
    long Array = Read_Long(Level + OFFSET::ActorArray);
    int Count = Read_Int(Level + OFFSET::ActorCount);

    int MyTeam = ViewMatrix._11>0?1:2;

    for (int i=0;i<Count;i++)
    {
        long actor = Read_Long(Array+i*0x18);
        if (actor < Imageaddress) continue;

        SmobaHeroData HeroData;

        HeroData.HeroTeam = GetPlayerTeam(actor);
        if (HeroData.HeroTeam == MyTeam) continue;

        HeroData.HeroID = GetPlayerHero(actor);
        HeroData.HeroHP = GetPlayerHeroHp(actor);
        if (HeroData.HeroHP <= 0) continue;

        HeroData.Pos = GetPlayerPos(actor);

        Players->push_back(HeroData);
    }
}

// ===================== 矩阵 =====================
bool RefreshMatrix()
{
    // ===== 新矩阵链（关键修复）=====
    long p1 = Read_Long(Imageaddress + OFFSET::ViewPort); // ★修改
    long p2 = Read_Long(p1 + OFFSET::Matrix_1);
    long p3 = Read_Long(p2 + OFFSET::Matrix_2);
    long p4 = Read_Long(p3 + OFFSET::Matrix_3);

    long matrixAddr = p4 + OFFSET::Matrix_Final;

    Read_Data(matrixAddr,64,&ViewMatrix);

    return true;
}

// ===================== 初始化 =====================
bool Gameinitialization()
{
    Imageaddress = get_module_base();

    Game_Data = Read_Long(Imageaddress + OFFSET::GWorld);      // ★修改
    Game_Viewport = Read_Long(Imageaddress + OFFSET::ViewPort);// ★修改

    return Game_Data > Imageaddress;
}
