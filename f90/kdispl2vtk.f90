!----------------------------------------------------------------------------
!   Copyright 2016 Florian Schumacher (Ruhr-Universitaet Bochum, Germany)
!
!   This file is part of ASKI version 1.2.
!
!   ASKI version 1.2 is free software: you can redistribute it and/or modify
!   it under the terms of the GNU General Public License as published by
!   the Free Software Foundation, either version 2 of the License, or
!   (at your option) any later version.
!
!   ASKI version 1.2 is distributed in the hope that it will be useful,
!   but WITHOUT ANY WARRANTY; without even the implied warranty of
!   MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
!   GNU General Public License for more details.
!
!   You should have received a copy of the GNU General Public License
!   along with ASKI version 1.2.  If not, see <http://www.gnu.org/licenses/>.
!----------------------------------------------------------------------------
program kdispl2vtk
  use inversionBasics
  use iterationStepBasics
  use kernelDisplacement
  use seismicEventList
  use seismicNetwork
  use wpVtkFile
  use invgridVtkFile
  use argumentParser
  use string
  use fileUnitHandler
  use errorMessage

  implicit none

  type (argument_parser) :: ap
  type (error_message) :: errmsg
  type (file_unit_handler) :: fuh
  type (inversion_basics) :: invbasics
  type (iteration_step_basics) :: iterbasics

  character(len=max_length_string) :: main_parfile

  character(len=max_length_string) :: evid,staname
  integer, dimension(:), pointer :: ifreq,ifreq_iterbasics
  character(len=max_length_string), dimension(:), pointer :: ucomp
  logical :: use_all_ucomp,use_selected_ucomp,use_all_ifreq,use_selected_ifreq,path_specific,&
       output_on_invgrid,force_average
  integer :: nucomp,iucomp,nfreq,jfreq
  real :: df_mdata,df_kd

  type (kernel_displacement) :: kd
  complex, dimension(:,:), pointer :: kd_ustr,kd_u
  character(len=max_length_string) :: kd_file
  integer :: nwp,ncell,icell,un,en

  type (wp_vtk_file), dimension(:), allocatable :: wp_vtk
  type (invgrid_vtk_file), dimension(:), allocatable :: ig_vtk
  complex, dimension(:), allocatable :: data
  character(len=max_length_string) :: vtk_file_base,vtk_file_title,vtk_file_data_name
  integer, dimension(:), pointer :: filled_cells,idx
  real, dimension(:), pointer :: w

  character (len=10) :: myname = 'kdispl2vtk'

  nullify(ifreq,ifreq_iterbasics,ucomp,kd_ustr,kd_u,filled_cells,idx,w)

!------------------------------------------------------------------------
!  definition and basic processing of command line
!
  call init(ap,myname,'Extract kernel displacement spectra to vtk files for certain wavefield and strain components and '//&
  'frequencies')
  call addPosarg(ap,'main_parfile','sval','Main parameter file of inversion')
  call addOption(ap,'-evid',.true.,"defines the event id of the kernel displacement object. This option must be set.",&
       'sval','')
  call addOption(ap,'-ifreq',.true.,"explicit vector of frequency indices at which the wavefield output should be extracted. "//&
       "Exactly one of options -ifreq , -all_ifreq must be set",'ivec','')
  call addOption(ap,'-all_ifreq',.false.,"if set, all frequency indices are used. Exactly one of options -ifreq , "//&
       "-all_ifreq must be set")
  call addOption(ap,'-ucomp',.true.,"explicit vector of wavefield components which can be 'ux', 'uy', 'uz' (denoting underived "//&
       "x,y,z components of wavefield) and 'exx', 'eyy', 'ezz', 'eyz', 'exz', 'exy' (denoting the strain components). "//&
       "Exactly one of options -ucomp , -all_ucomp must be set'",'svec','')
  call addOption(ap,'-all_ucomp',.false.,"if set, all wavefield components are (3 underived and 6 strain components). "//&
       "Exactly one of options -ucomp , -all_ucomp must be set")
  call addOption(ap,'-staname',.true.,"ONLY REQUIRED FOR PATH-SPECIFIC MODE, defines the station name of the path.",&
       'sval','')
  call addOption(ap,'-on_invgrd',.false.,"if set, the output spectra will be interpolated onto the inversion grid (useful "//&
       "for benchmarking with another forward method)")
  call addOption(ap,'-average',.false.,"only in case of -on_invgrd: build the average on inversion grid cells. If -average is "//&
       "not set, -on_invgrd interpolates by integration on cells (using integration weights) and dividing by the sum of weights "//&
       "(approx. cell volume).")
!
  call parse(ap)
  if (.level.(.errmsg.ap) == 2) then
     call print(.errmsg.ap)
     call usage(ap)
     goto 1
  end if
!
  main_parfile = ap.sval.'main_parfile'
  if (.level.(.errmsg.ap) == 2) then
     call print(.errmsg.ap)
     call usage(ap)
     goto 1
  end if
!
  use_all_ucomp = ap.optset.'-all_ucomp'
  use_selected_ucomp = ap.optset.'-ucomp'
  if(use_all_ucomp .eqv. use_selected_ucomp) then
     write(*,*) "ERROR: exactly ONE of the options -ucomp and -all_ucomp must be set!"
     call usage(ap)
     goto 1
  end if
!
  use_all_ifreq = ap.optset.'-all_ifreq'
  use_selected_ifreq = ap.optset.'-ifreq'
  if(use_all_ifreq .eqv. use_selected_ifreq) then
     write(*,*) "ERROR: exactly ONE of the options -ifreq and -all_ifreq must be set!"
     call usage(ap)
     goto 1
  end if
!
  if(.not.(ap.optset.'-evid')) then
     write(*,*) "ERROR: option -evid must be set!"
     call usage(ap)
     goto 1
  end if
  evid = ap.sval.'-evid'
!
  output_on_invgrid = ap.optset.'-on_invgrd'
  force_average = ap.optset.'-average'
  if(force_average .and. (.not.output_on_invgrid)) then
     write(*,*) "ERROR: -average can only be set when -on_invgrd was set"
     call usage(ap)
     goto 1
  end if

!------------------------------------------------------------------------
!  setup basics
!
  call new(fuh,20)
!
  call new(errmsg,myname)
  call init(invbasics,trim(main_parfile),get(fuh),errmsg)
  call undo(fuh)
  if (.level.errmsg /= 0) call print(errmsg)
  if (.level.errmsg == 2) goto 1
  call dealloc(errmsg)
!
!  setup iteration step basics
!
  call new(errmsg,myname)
  call init(iterbasics,invbasics,fuh,errmsg)
  if (.level.errmsg /= 0) call print(errmsg)
  if (.level.errmsg == 2) goto 1
  call dealloc(errmsg)
!
  ifreq_iterbasics => .ifreq.iterbasics
  df_mdata = .df.invbasics
  path_specific = lval(.inpar.iterbasics,'USE_PATH_SPECIFIC_MODELS')
  if(path_specific) then
     if(.not.(ap.optset.'-staname')) then
        write(*,*) "ERROR: path-specific mode enabled in iteration-step parameter file; in this case, option -staname must be set!"
        call usage(ap)
        goto 1
     end if
     staname = ap.sval.'-staname'
  end if

!------------------------------------------------------------------------
!  detailed processing of command line arguments
!
  if(use_selected_ucomp) then
     ucomp => ap.svec.'-ucomp'
     if(.not.(associated(ucomp))) then
        write(*,*) "ERROR: no components could be read from the argument of -ucomp"
        call usage(ap)
        goto 1
     end if
     nucomp = size(ucomp)
     do iucomp = 1,nucomp
        select case (ucomp(iucomp))
        case('ux','uy','uz','exx','eyy','ezz','eyz','exz','exy')
           ! OK, do nothing
        case default
           write(*,*) "ERROR: ",iucomp,"'th wavefield component '",trim(ucomp(iucomp)),&
                "' of the -ucomp argument string is not one of 'ux','uy','uz','exx','eyy','ezz','eyz','exz','exy'"
           call usage(ap)
           goto 1
        end select
     end do ! iucomp
  else ! use_selected_ucomp
     nucomp = 9
     allocate(ucomp(nucomp))
     ucomp = (/'ux ','uy ','uz ','exx','eyy','ezz','eyz','exz','exy'/)
  end if ! use_selected_ucomp
!
  if(use_selected_ifreq) then
     ifreq => ap.ivec.'-ifreq'
     if(.not.(associated(ifreq))) then
        write(*,*) "ERROR: no frequency indices could be read from the argument of -ifreq"
        call usage(ap)
        goto 1
     end if
     nfreq = size(ifreq)
     do jfreq = 1,nfreq
        if(.not.any(ifreq(jfreq)==ifreq_iterbasics)) then
           write(*,*) "ERROR: ",jfreq,"'th frequency index ",ifreq(jfreq)," of the -ifreq argument string is not "//&
                "contained in the frequency indices of the current iteration step: ",ifreq_iterbasics
           call usage(ap)
           goto 1
        end if
     end do ! iucomp
  else ! use_selected_ifreq
     nfreq = size(ifreq_iterbasics)
     allocate(ifreq(nfreq))
     ifreq = ifreq_iterbasics
  end if ! use_selected_ifreq
!
  errmsg = searchEventidSeismicEventList(.evlist.invbasics,evid)
  if(.level. errmsg/=0) then
     write(*,*) "ERROR: event ID '"//trim(evid)//"' (input string of option -evid) is not contained in event list"
     goto 1
  end if
  call dealloc(errmsg)
!
  if(path_specific) then
     errmsg = searchStationNameSeismicNetwork(.statlist.invbasics,staname)
     if(.level. errmsg/=0) then
        write(*,*) "ERROR: station name '"//trim(staname)//"' (input string of option -staname) is not contained in station list"
        goto 1
     end if
     call dealloc(errmsg)
  end if
!
  call document(ap)
  write(*,*) ""

!------------------------------------------------------------------------
!  prepare for the loop below
!
  if(output_on_invgrid) then
     if(force_average) then
        write(*,*) "WILL INTERPOLATE KERNEL DISPLACEMENT TO INVERSION GRID (forcing average over cells)"
     else
        write(*,*) "WILL INTERPOLATE KERNEL DISPLACEMENT TO INVERSION GRID (integration followed by division ",&
             "by sum of ingteration weights)"
     end if
  else
     write(*,*) "WILL WRITE KERNEL DISPLACEMENT ON WAVEFIELD POINTS"
  end if
  write(*,*) ""
!
  if(path_specific) then
     kd_file = trim(.iterpath.invbasics)//trim((.inpar.iterbasics).sval.'PATH_KERNEL_DISPLACEMENTS')//&
          'kernel_displ_'//trim(evid)//'_'//trim(staname)
     write(*,*) "OPEN KERNEL DISPLACEMENT FILE '",trim(kd_file),"' TO READ (detected path-specific mode)"
  else
     kd_file = trim(.iterpath.invbasics)//trim((.inpar.iterbasics).sval.'PATH_KERNEL_DISPLACEMENTS')//&
          'kernel_displ_'//trim(evid)
     write(*,*) "OPEN KERNEL DISPLACEMENT FILE '",trim(kd_file),"' TO READ"
  end if
  call new(errmsg,myname)
  call initiateKernelDisplacement(kd,(.inpar.invbasics).sval.'FORWARD_METHOD',fuh,kd_file,errmsg)
  if (.level.errmsg /= 0) call print(errmsg)
  if (.level.errmsg == 2) goto 1
  call dealloc(errmsg)
  df_kd = .df.kd
  if( abs(df_kd-df_mdata) > (1.e-4*df_kd) ) then
     write(*,*) "ERROR: frequency step df of kernel displacement ( = ",df_kd,") differs from frequency "//&
          "step df of measured data, as defined in main parfile ( = ",df_mdata,"), by more than 0.01 "//&
          "percent; this could mean that the kernel displacement object was created w.r.t. a different setting."
     goto 1
  end if
  write(*,*) ""
!
  nwp = .ntot.(.wp.iterbasics)
  if(output_on_invgrid) then
     filled_cells => getFilledCells(.intw.iterbasics)
     if(.not.associated(filled_cells)) then
        write(*,*) "ERROR: the inversion grid was not set-up properly or all cells do not contain any wavefield points"
        goto 1
     end if
     ncell = size(filled_cells)
     do icell = 1,ncell
        ! check for consistency (then no need to do it below in loop)
        idx => (.intw.iterbasics).wpidx.(filled_cells(icell))
        if(.not.associated(idx)) then
           write(*,*) "ERROR: even though inversion grid cell index ",filled_cells(icell)," is said to contain ",&
                "wavefield points, the integration weights object does not return any wavefield point indices for ",&
                "it -> integration weights object is inconsistent!"
           goto 1
        end if
        if(any(idx<1 .or. idx>nwp)) then
           write(*,*) "ERROR: there are ",count(idx<1 .or. idx>nwp)," invalid wavefield point indices returned for ",&
                "invgrid cell index ",filled_cells(icell)," -> integration weights object is inconsistent!"
           goto 1
        end if
        if(force_average) then
           ! check for consistency (then no need to do it below in loop)
           w => (.intw.iterbasics).weight.(filled_cells(icell))
           if(.not.associated(w)) then
              write(*,*) "ERROR: even though inversion grid cell index ",filled_cells(icell)," is said to ",&
                   "contain wavefield points, the integration weights object does not return any weights for ",&
                   "it -> integration weights object is inconsistent!"
              goto 1
           end if
        end if
     end do ! icell
     allocate(ig_vtk(nucomp))
     allocate(data(ncell))
  else ! output_on_invgrid
     allocate(wp_vtk(nucomp))
     allocate(data(nwp))
  end if ! output_on_invgrid
  
!------------------------------------------------------------------------
!  now loop on all frequencies and components, read kernel displ and write
!
  do jfreq = 1,nfreq
     write(*,*) "PROCESSING FREQUENCY INDEX ",ifreq(jfreq)

     call new(errmsg,myname) ! use one error message for the next few calls

     call readFrequencyKernelDisplacement(kd,ifreq(jfreq),errmsg)
     if (.level.errmsg == 2) then; call print(errmsg); goto 1; endif

     call getKernelDisplacement(kd,kd_u,errmsg)
     if (.level.errmsg == 2) then; call print(errmsg); goto 1; endif
     if(.not.associated(kd_u)) then
        write(*,*) "ERROR: no kernel displacement values were returned, this error should not have occurred!"
        if (.level.errmsg /= 0) call print(errmsg)
        goto 1
     end if
     if(size(kd_u,1) /= nwp) then
        write(*,*) "ERROR: kernel displacement object has ",size(kd_u,1)," values, but there are ",nwp," wavefield points"
        if (.level.errmsg /= 0) call print(errmsg)
        goto 1
     end if

     call getStrainsKernelDisplacement(kd,kd_ustr,errmsg)
     if (.level.errmsg == 2) then; call print(errmsg); goto 1; endif
     if(.not.associated(kd_ustr)) then
        write(*,*) "ERROR: no kernel displacement strain values were returned, this error should not have occurred!"
        if (.level.errmsg /= 0) call print(errmsg)
        goto 1
     end if
     if(size(kd_ustr,1) /= nwp) then
        write(*,*) "ERROR: kernel displacement strains have ",size(kd_u,1)," values, but there are ",nwp," wavefield points"
        if (.level.errmsg /= 0) call print(errmsg)
        goto 1
     end if

     if (.level.errmsg /= 0) call print(errmsg)
     call dealloc(errmsg)

     ! loop on all wavefield components
     do iucomp=1,nucomp
        un = -1; en = -1
        select case(ucomp(iucomp))
        case ('ux'); un = 1
        case ('uy'); un = 2
        case ('uz'); un = 3
        case ('exx'); en = 1
        case ('eyy'); en = 2
        case ('ezz'); en = 3
        case ('eyz'); en = 4
        case ('exz'); en = 5
        case ('exy'); en = 6
        end select

        if(output_on_invgrid) then
           ! in case that this is an underived wavefield component, get kernel displacement at correct component
           if(un > 0) call interpolate_wp_onto_invgrid(kd_u(:,un))
           ! in case that this is a strain component, get strain at correct component
           if(en > 0) call interpolate_wp_onto_invgrid(kd_ustr(:,en))
        else ! output_on_invgrid
           ! in case that this is an underived wavefield component, get kernel displacement at correct component
           if(un > 0) data = kd_u(:,un)
           ! in case that this is a strain component, get strain at correct component
           if(en > 0) data = kd_ustr(:,en)
        end if ! output_on_invgrid

        ! finally write vtk file

        if(jfreq==1) then
           ! initiate vtk file
           write(vtk_file_title,*) trim(ucomp(iucomp)),"-component of spectral kernel displacement at frequency ",&
                ifreq(jfreq)*df_mdata,' Hz on wavefield points'
           call new(errmsg,myname)
           if(output_on_invgrid) then
              write(vtk_file_base,"(a,'_ON-INVGRID_',a)") trim(kd_file),trim(ucomp(iucomp))
              call init(ig_vtk(iucomp),.invgrid.iterbasics,trim(vtk_file_base),&
                   trim((.inpar.invbasics).sval.'DEFAULT_VTK_FILE_FORMAT'),errmsg,vtk_title=trim(vtk_file_title),&
                   cell_indx_req=filled_cells)
           else
              write(vtk_file_base,"(a,'_',a)") trim(kd_file),trim(ucomp(iucomp))
              call init(wp_vtk(iucomp),.wp.iterbasics,.invgrid.iterbasics,trim(vtk_file_base),&
                   trim((.inpar.invbasics).sval.'DEFAULT_VTK_FILE_FORMAT'),errmsg,vtk_title=trim(vtk_file_title))
           end if
           if (.level.errmsg /= 0) call print(errmsg)
           if (.level.errmsg == 2) goto 1
           call dealloc(errmsg)
           print *,"    creating vtk files with basename '"//trim(vtk_file_base)//"' (plus extension for each frequency index)"
        end if ! jfreq==1

        ! write kdispl values to vtk file
        write(vtk_file_data_name,*) trim(ucomp(iucomp)),'-kdispl'
        call new(errmsg,myname)
        if(output_on_invgrid) then
           call writeData(ig_vtk(iucomp),get(fuh),data,errmsg,data_name=trim(vtk_file_data_name),file_index=ifreq(jfreq))
        else
           call writeData(wp_vtk(iucomp),get(fuh),data,errmsg,data_name=trim(vtk_file_data_name),file_index=ifreq(jfreq))
        end if
        call undo(fuh)
        if (.level.errmsg /= 0) call print(errmsg)
        if (.level.errmsg == 2) goto 1
        call dealloc(errmsg)

     end do ! iucomp

     if(associated(kd_ustr)) deallocate(kd_ustr)
     if(associated(kd_u)) deallocate(kd_u)

  end do ! jfreq

!------------------------------------------------------------------------
!  clean up before terminating the program
!
1   call dealloc(iterbasics); call dealloc(invbasics)
    call dealloc(fuh)
    call dealloc(errmsg)
    call dealloc(ap)
    if(associated(ifreq)) deallocate(ifreq)
    if(associated(ucomp)) deallocate(ucomp)
    if(associated(kd_ustr)) deallocate(kd_ustr)
    if(associated(kd_u)) deallocate(kd_u)
    if(allocated(wp_vtk)) then
       do iucomp = 1,nucomp
          call dealloc(wp_vtk(iucomp))
       end do ! iucomp
       deallocate(wp_vtk)
    end if
    if(allocated(ig_vtk)) then
       do iucomp = 1,nucomp
          call dealloc(ig_vtk(iucomp))
       end do ! iucomp
       deallocate(ig_vtk)
    end if
    if(allocated(data)) deallocate(data)
    if(associated(filled_cells)) deallocate(filled_cells)

contains

  subroutine interpolate_wp_onto_invgrid(data_on_wp)
    complex, dimension(:) :: data_on_wp ! assume incoming array to have size nwp !

    do icell = 1,ncell
       idx => (.intw.iterbasics).wpidx.(filled_cells(icell))
       if(force_average) then
          data(icell) = cmplx( sum(dcmplx(data_on_wp(idx)))/dble(size(idx)) )
       else
          w => (.intw.iterbasics).weight.(filled_cells(icell))
          data(icell) = cmplx( sum(dble(w)*dcmplx(data_on_wp(idx)))/sum(dble(w)) )
       end if
    end do ! icell
  end subroutine interpolate_wp_onto_invgrid

end program kdispl2vtk
