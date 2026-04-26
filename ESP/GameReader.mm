#include "Utilties.h"
#include <mach/mach.h>
#include <dlfcn.h>
#include <mach-o/dyld_images.h>
#include <stdio.h>
#include "crossproc.h"

// ================= 偏移定义（已替换为HTML版本） =================
namespace Offset
{
    // ===== 世界（原Game_Data）=====
    constexpr long GAME_DATA = 0x1338ED90;

    // ===== 矩阵（原Game_Viewport）=====
    constexpr long GAME_VIEWPORT = 0x12DFB130;
    constexpr long VIEWPORT_P1 = 0xB8;
    constexpr long VIEWPORT_P2 = 0x0;
    constexpr long VIEWPORT_P3 = 0x8;
    constexpr long VIEW_MATRIX = 0x128;

    // ===== 玩家数组 =====
    constexpr long LEVEL = 0x138;
    constexpr long PLAYER_ARRAY = 0x60;
    constexpr long PLAYER_COUNT = 0x7C;

    // ===== 玩家属性 =====
    constexpr long PLAYER_TEAM = 0x5C;
    constexpr long PLAYER_HERO_ID = 0x50;

    // ===== 血量 =====
    constexpr long PLAYER_HP_PTR = 0x188;
    constexpr long HP_CURRENT = 0xA8;
    constexpr long HP_MAX = 0xB0;

    // ===== 坐标链 =====
    constexpr long PLAYER_POS = 0x268;
    constexpr long POS_P1 = 0x10;
    constexpr long POS_P2 = 0x0;
    constexpr long POS_P3 = 0x60;

    constexpr long POS_X = 0x0;
    constexpr long POS_Y = 0x8;
}

// ================= 原有全局变量（不动） =================
long Imageaddress, Game_Data, Game_Viewport;
static mach_port_t task;

Matrix ViewMatrix;

static float MemPosx;
static float MemPosy;

// ================= 进程获取（不动） =================
static int get_processes_pid() {
    static int PID;
    size_t length = 0;
    int mib[] = {CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0};

    sysctl(mib, 4, NULL, &length, NULL, 0);
    struct kinfo_proc *procBuffer = (struct kinfo_proc *)malloc(length);

    sysctl(mib, 4, procBuffer, &length, NULL, 0);
    int count = length / sizeof(struct kinfo_proc);

    for (int i = 0; i < count; i++) {
        NSString *name = [NSString stringWithUTF8String:procBuffer[i].kp_proc.p_comm];
        if ([name containsString:@"smoba"]) {
            task_for_pid(mach_task_self(), procBuffer[i].kp_proc.p_pid, &task);
            PID = procBuffer[i].kp_proc.p_pid;
        }
    }
    return PID;
}

// ================= 模块基址（不动） =================
static long get_module_base() {
    get_processes_pid();

    task_dyld_info_data_t info;
    mach_msg_type_number_t count = TASK_DYLD_INFO_COUNT;
    task_info(task, TASK_DYLD_INFO, (task_info_t)&info, &count);

    dyld_all_image_infos64 aii;
    mach_vm_size_t size = sizeof(aii);
    mach_vm_read_overwrite(task, info.all_image_info_addr, size, (mach_vm_address_t)&aii, &size);

    auto* list = (dyld_image_info64*)malloc(aii.infoArrayCount * sizeof(dyld_image_info64));
    mach_vm_read(task, aii.infoArray, size, (vm_offset_t*)&list, &size);

    for (int i = 0; i < aii.infoArrayCount; i++) {
        char path[1024] = {0};
        mach_vm_size_t out;
        mach_vm_read_overwrite(task, (mach_vm_address_t)list[i].imageFilePath, 1024, (mach_vm_address_t)path, &out);

        NSString *name = [NSString stringWithUTF8String:path];
        if ([name containsString:@"UnityFramework"])
            return (long)list[i].imageLoadAddress;
    }
    return 0;
}

// ================= 基础读写（不动） =================
static bool Read_Data(long Src,int Size,void* Dst)
{
    vm_size_t size = 0;
    return vm_read_overwrite(task, Src, Size, (vm_address_t)Dst, &size) == KERN_SUCCESS;
}

static long Read_Long(long src){ long v=0; Read_Data(src,8,&v); return v; }
static int Read_Int(long src){ int v=0; Read_Data(src,4,&v); return v; }

// ================= 玩家血量（已替换偏移） =================
static float GetPlayerHeroHp(long Target)
{
    long hpPtr = Read_Long(Target + Offset::PLAYER_HP_PTR);
    int hp = Read_Int(hpPtr + Offset::HP_CURRENT);
    int max = Read_Int(hpPtr + Offset::HP_MAX);

    if (hp <= 0 || max <= 0) return 0;
    return (float)hp / max;
}

// ================= 阵营（已替换偏移） =================
static int GetPlayerTeam(long Target)
{
    return Read_Int(Target + Offset::PLAYER_TEAM);
}

// ================= HeroID（已替换偏移） =================
static int GetPlayerHero(long Target)
{
    return Read_Int(Target + Offset::PLAYER_HERO_ID);
}

// ================= 坐标（完全替换为新链） =================
static Vector2 GetPlayerPos(long Target)
{
    long p1 = Read_Long(Target + Offset::PLAYER_POS);
    long p2 = Read_Long(p1 + Offset::POS_P1);
    long p3 = Read_Long(p2 + Offset::POS_P2);
    long p4 = Read_Long(p3 + Offset::POS_P3);

    int x = Read_Int(p4 + Offset::POS_X);
    int y = Read_Int(p4 + Offset::POS_Y);

    MemPosx = x / 1000.0f;
    MemPosy = y / 1000.0f;

    return {MemPosx, MemPosy};
}

// ================= 玩家遍历（核心改动） =================
void GetPlayers(std::vector<SmobaHeroData> *Players)
{
    Players->clear();

    // 原：Read_Long(Read_Long(Game_Data)+0x380)
    // 新：GWorld -> Level
    long Level = Read_Long(Game_Data + Offset::LEVEL);
    if (Level < Imageaddress) return;

    int MyTeam = ViewMatrix._11 > 0 ? 1 : 2;

    long Array = Read_Long(Level + Offset::PLAYER_ARRAY);
    int ArraySize = Read_Int(Level + Offset::PLAYER_COUNT);

    if (ArraySize <= 0 || ArraySize > 50) return;

    for (int i = 0; i < ArraySize; i++) {
        long P_player = Read_Long(Array + i * 0x18);
        if (P_player < Imageaddress) continue;

        SmobaHeroData HeroData;

        HeroData.HeroHP = GetPlayerHeroHp(P_player);
        HeroData.HeroID = GetPlayerHero(P_player);
        HeroData.HeroTeam = GetPlayerTeam(P_player);
        HeroData.Pos = GetPlayerPos(P_player);

        if (HeroData.HeroTeam != MyTeam)
            Players->push_back(HeroData);
    }
}

// ================= 矩阵（已替换链） =================
bool RefreshMatrix()
{
    long addr =
        Read_Long(
            Read_Long(
                Read_Long(
                    Game_Viewport + Offset::VIEWPORT_P1
                ) + Offset::VIEWPORT_P2
            ) + Offset::VIEWPORT_P3
        );

    addr = Read_Long(addr);

    if (addr < Imageaddress) return false;

    Read_Data(addr + Offset::VIEW_MATRIX, 64, &ViewMatrix);
    return true;
}

// ================= 初始化（关键改动） =================
bool Gameinitialization()
{
    Imageaddress = get_module_base();

    // 新：GWorld
    Game_Data = Read_Long(Imageaddress + Offset::GAME_DATA);

    // 新：矩阵基址（不再Read）
    Game_Viewport = Imageaddress + Offset::GAME_VIEWPORT;

    return Game_Data > Imageaddress;
}
