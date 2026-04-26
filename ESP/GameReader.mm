#include "Utilties.h"
#include <mach/mach.h>
#include <mach-o/dyld_images.h>
#include <sys/sysctl.h>
#include <vector>

// ================= 偏移定义（统一管理） =================
namespace Offset
{
    // ===== 世界 =====
    constexpr long GWORLD = 0x1338ED90;

    // ===== 矩阵 =====
    constexpr long MATRIX_BASE = 0x12DFB130;
    constexpr long MATRIX_CHAIN_1 = 0xB8;
    constexpr long MATRIX_CHAIN_2 = 0x0;
    constexpr long MATRIX_CHAIN_3 = 0x8;
    constexpr long MATRIX_DATA = 0x128;

    // ===== Level / Actor =====
    constexpr long LEVEL = 0x138;
    constexpr long ACTOR_ARRAY = 0x60;
    constexpr long ACTOR_COUNT = 0x7C;

    // ===== Actor属性 =====
    constexpr long TEAM = 0x5C;
    constexpr long HERO_ID = 0x50;

    // ===== 血量 =====
    constexpr long HP_ROOT = 0x188;
    constexpr long HP = 0xA8;
    constexpr long HP_MAX = 0xB0;

    // ===== 坐标链 =====
    constexpr long POS_ROOT = 0x268;
    constexpr long POS_1 = 0x10;
    constexpr long POS_2 = 0x0;
    constexpr long POS_3 = 0x60;

    constexpr long POS_X = 0x0;
    constexpr long POS_Y = 0x8;
}

// ================= 全局变量 =================
static mach_port_t task;
long Imageaddress;

// 4x4矩阵（16个float）
float Matrix[16];

// ================= 基础内存读取 =================
bool Read_Data(long addr, int size, void* out)
{
    vm_size_t outSize = 0;
    return vm_read_overwrite(task, addr, size, (vm_address_t)out, &outSize) == KERN_SUCCESS;
}

long Read_Long(long addr)
{
    long v = 0;
    Read_Data(addr, 8, &v);
    return v;
}

int Read_Int(long addr)
{
    int v = 0;
    Read_Data(addr, 4, &v);
    return v;
}

float Read_Float(long addr)
{
    float v = 0;
    Read_Data(addr, 4, &v);
    return v;
}

// ================= 获取进程 =================
int GetProcessPID()
{
    size_t size = 0;
    int mib[4] = {CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0};

    sysctl(mib, 4, NULL, &size, NULL, 0);
    auto* list = (kinfo_proc*)malloc(size);

    sysctl(mib, 4, list, &size, NULL, 0);
    int count = size / sizeof(kinfo_proc);

    for (int i = 0; i < count; i++)
    {
        NSString* name = [NSString stringWithUTF8String:list[i].kp_proc.p_comm];
        if ([name containsString:@"smoba"])
        {
            task_for_pid(mach_task_self(), list[i].kp_proc.p_pid, &task);
            return list[i].kp_proc.p_pid;
        }
    }
    return 0;
}

// ================= 获取模块基址 =================
long get_module_base()
{
    GetProcessPID();

    task_dyld_info_data_t info;
    mach_msg_type_number_t count = TASK_DYLD_INFO_COUNT;

    task_info(task, TASK_DYLD_INFO, (task_info_t)&info, &count);

    dyld_all_image_infos64 aii;
    mach_vm_size_t size = sizeof(aii);

    mach_vm_read_overwrite(task, info.all_image_info_addr, size, (mach_vm_address_t)&aii, &size);

    auto* list = (dyld_image_info64*)malloc(aii.infoArrayCount * sizeof(dyld_image_info64));
    mach_vm_read(task, aii.infoArray, size, (vm_offset_t*)&list, &size);

    for (int i = 0; i < aii.infoArrayCount; i++)
    {
        char path[1024] = {0};
        mach_vm_size_t out;

        mach_vm_read_overwrite(task, (mach_vm_address_t)list[i].imageFilePath, 1024, (mach_vm_address_t)path, &out);

        NSString* name = [NSString stringWithUTF8String:path];
        if ([name containsString:@"UnityFramework"])
        {
            return (long)list[i].imageLoadAddress;
        }
    }
    return 0;
}

// ================= 刷新矩阵 =================
bool RefreshMatrix()
{
    long addr =
        Read_Long(
            Read_Long(
                Read_Long(
                    Read_Long(Imageaddress + Offset::MATRIX_BASE)
                    + Offset::MATRIX_CHAIN_1)
                + Offset::MATRIX_CHAIN_2)
            + Offset::MATRIX_CHAIN_3);

    if (addr < Imageaddress) return false;

    // 读取16个float
    for (int i = 0; i < 16; i++)
    {
        Matrix[i] = Read_Float(addr + Offset::MATRIX_DATA + i * 4);
    }

    return true;
}

// ================= 世界坐标 → 屏幕坐标 =================
bool WorldToScreen(float x, float y, Vector2* out, float width, float height)
{
    float w = Matrix[2] * x + Matrix[10] * y + Matrix[14];
    if (w < 0.01f) return false;

    out->x = (1 + (Matrix[0] * x + Matrix[8] * y + Matrix[12]) / w) * width / 2;
    out->y = (1 - (Matrix[1] * x + Matrix[9] * y + Matrix[13]) / w) * height / 2;

    return true;
}

// ================= 获取玩家列表 =================
void GetPlayers(std::vector<SmobaHeroData>* list, float screenW, float screenH)
{
    list->clear();

    // 读取GWorld
    long GWorld = Read_Long(Imageaddress + Offset::GWORLD);
    if (GWorld < 0x100000000) return;

    long Level = Read_Long(GWorld + Offset::LEVEL);
    long ActorArray = Read_Long(Level + Offset::ACTOR_ARRAY);
    int Count = Read_Int(Level + Offset::ACTOR_COUNT);

    int myTeam = Matrix[0] > 0 ? 1 : 2;

    for (int i = 0; i < Count; i++)
    {
        long actor = Read_Long(ActorArray + i * 0x18);
        if (actor < Imageaddress) continue;

        int team = Read_Int(actor + Offset::TEAM);
        if (team == myTeam) continue;

        // ===== 血量 =====
        long hpPtr = Read_Long(actor + Offset::HP_ROOT);
        int hp = Read_Int(hpPtr + Offset::HP);
        int hpmax = Read_Int(hpPtr + Offset::HP_MAX);

        if (hp <= 0 || hp > hpmax) continue;

        // ===== 坐标 =====
        long p1 = Read_Long(actor + Offset::POS_ROOT);
        long p2 = Read_Long(p1 + Offset::POS_1);
        long p3 = Read_Long(p2 + Offset::POS_2);
        long p4 = Read_Long(p3 + Offset::POS_3);

        float x = Read_Int(p4 + Offset::POS_X) / 1000.0f;
        float y = Read_Int(p4 + Offset::POS_Y) / 1000.0f;

        Vector2 screen;
        if (!WorldToScreen(x, y, &screen, screenW, screenH))
            continue;

        // ===== 填充数据 =====
        SmobaHeroData data;
        data.HeroID = Read_Int(actor + Offset::HERO_ID);
        data.HeroHP = (float)hp / hpmax;
        data.HeroTeam = team;
        data.Pos = {x, y};
        data.ScreenPos = screen;
        data.Dead = (hp <= 0);

        list->push_back(data);
    }
}

// ================= 初始化 =================
bool Gameinitialization()
{
    Imageaddress = get_module_base();
    return Imageaddress > 0;
}