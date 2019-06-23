[CCode (cheader_filename="io.h", lower_case_cprefix = "")]
namespace Win
{
    [CCode (cname = "_get_osfhandle")]
    void* GetFileHandle(uint fd);
}