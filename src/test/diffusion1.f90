!----------------------------------------------------------------------------- best with 100 columns

function diffusion1() result(ierr)
  use modFileIO
  use modPolyFvGrid
  use modReconstruction
  use modGradient
  use modDiffusion
  integer ierr
  type(polyFvGrid)::grid
  double precision,allocatable::s(:),grads(:,:),gradsr(:,:),D(:),tmps(:)
  double precision::p(3),dt
  
  ierr=0
  open(10,file='data/bar_tet.vtk',action='read')
  call readVTK(10,grid)
  close(10)
  call grid%up()
  allocate(s(grid%nC))
  allocate(D(grid%nP))
  D(:)=1d-3
  do i=1,grid%nC
    p=grid%p(i)
    if(p(1)<0.6d0.and.p(1)>0.4d0)then
      s(i)=1d0
    else if(p(1)<0.3d0.and.p(1)>0.1d0)then
      s(i)=sin((p(1)-0.1d0)*40d0*atan(1d0))
    else
      s(i)=0d0
    end if
  end do
  dt=0.0005d0
  do l=1,200
    call findGrad(grid,s,grads)
    call reconSD(grid,s,grads,gradsr)
    call findDfs(grid,D,gradsr,tmps)
    s(:)=s(:)+dt*tmps(:)/grid%v(:)
  end do
  open(10,file='diffusion1_rst.vtk',action='write')
  call writeVTK(10,grid)
  call writeVTK(10,grid,E_DATA)
  call writeVTK(10,'s',[s,[(0d0,i=1,grid%nE-grid%nC)]])
  close(10)
  call grid%clear()
  deallocate(s,grads,gradsr,D,tmps)
end function
