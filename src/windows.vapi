/**
 * A few native Win32 functions to fill some gaps.
 */
[CCode (cprefix = "", lower_case_cprefix = "", cheader_filename = "windows.h")]
namespace Windows {
  void* _get_osfhandle (int fd);
  int _dup (int fd);
  int _dup2 (int fd1, int fd2);
  int _close (int fd);
}
